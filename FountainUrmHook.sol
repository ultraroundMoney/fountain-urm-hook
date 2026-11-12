// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTokenWrapperHook} from "@uniswap/v4-periphery/src/base/hooks/BaseTokenWrapperHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "./IERC20.sol";
import {IUrm} from "./IUrm.sol";
import {IERC4626} from "./IERC4626.sol";
import {IFountainUrm} from "./IFountainUrm.sol";
import {IFountainUrmHook} from "./IFountainUrmHook.sol";
import {IUrmDualOwnership} from "./IUrmDualOwnership.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {TowerStructs} from "./TowerStructs.sol";

// FountainUrmHook
contract FountainUrmHook is BaseTokenWrapperHook, IUnlockCallback, IFountainUrmHook, ReentrancyGuard {
  using CurrencyLibrary for Currency;

  // constant
  IPoolManager private constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
  IUrm private constant URM = IUrm(0xF0E3349f00972475a5D16721796091AA3B997837);
  address private constant URM_FORTRESS = 0xd3e9637Cfc255AD3FffA1e88Bd9BA7fa5a76b4Fe;
  IUrmDualOwnership private constant UDO = IUrmDualOwnership(0x268B9Be506E7338a3461256cfe86BAE7205aA9bc);
  IERC4626 private constant FOUNTAIN = IERC4626(0x95fa3FA511Ef8DD9e48453eaE76b241D1c1AC651); // the vault, also the fURM token. A new vault means a new hook: the routing allowlist refuses upgradeable hooks
  IERC20 private constant FURM = IERC20(0x95fa3FA511Ef8DD9e48453eaE76b241D1c1AC651); // the same contract as its share token
  uint256 private constant VERSION = 1;
  uint256 private constant PCT = 100;
  uint256 private constant MAX_URM_TARGET = 1_000_000e18; // ceiling for CONFIG.urmTarget
  uint256 private constant DEFAULT_URM_TARGET = 25_000e18; // CONFIG.urmTarget at deployment
  uint256 private constant MAX_MIN_FLOAT_PERCENT = 50; // ceiling for CONFIG.minFloatPercent
  uint256 private constant MIN_SYNC_INTERVAL = 15 minutes; // floor for CONFIG.syncInterval
  uint256 private constant MAX_SYNC_INTERVAL = 1 days; // ceiling for CONFIG.syncInterval
  uint256 private constant CONFIG_INTERVAL = 1 hours; // min seconds between setConfigs calls

  // state
  TowerStructs.FountainHookConfig private CONFIG;
  TowerStructs.FountainHookState private STATE;

  // constructor
  // sets the default config and approves the vault for the URM wraps deposit; the vault's asset must be URM, so a wrong
  // constant fails here. The address must carry the v4 permission bits (CREATE2 with a mined salt); the pool key is URM/fURM at fee 0
  constructor() BaseTokenWrapperHook(POOL_MANAGER, Currency.wrap(address(FOUNTAIN)), Currency.wrap(address(URM))) {
    require(FOUNTAIN.asset() == address(URM), "conf");
    URM.approve(address(FOUNTAIN), type(uint256).max);
    STATE.lastSync = block.timestamp;

    CONFIG = TowerStructs.FountainHookConfig({
      urmTarget: DEFAULT_URM_TARGET,
      minFloatPercent: 10,
      syncInterval: 6 hours
    });
  }

  // withdrawToken
  // URM is the float and fURM is awaiting redemption, neither is ever withdrawn; any other stray token can be swept to the multisig
  function withdrawToken(address tokenAdr) external nonReentrant {
    require(msg.sender == getAutomator(), "auth");
    require(tokenAdr != address(URM) && tokenAdr != address(FOUNTAIN), "tok");

    IERC20 token = IERC20(tokenAdr);
    uint256 balance = token.balanceOf(address(this));
    require(balance > 0, "bal");
    require(token.transfer(UDO.getMultisig(), balance), "xfer");
  }

  // setConfigs
  // updates the float target, the reserve percent and the sync cadence; automator only, 1-hour cooldown. A lower target
  // takes effect at the next sync, which burns the float above it
  function setConfigs(TowerStructs.FountainHookConfig calldata newConfig) external nonReentrant {
    require(msg.sender == getAutomator(), "auth");
    require(block.timestamp >= STATE.nextConfigTime, "cool");
    require(newConfig.urmTarget <= MAX_URM_TARGET, "conf");
    require(newConfig.minFloatPercent <= MAX_MIN_FLOAT_PERCENT, "conf");
    require(newConfig.syncInterval >= MIN_SYNC_INTERVAL && newConfig.syncInterval <= MAX_SYNC_INTERVAL, "conf");

    CONFIG = newConfig;
    STATE.nextConfigTime = block.timestamp + CONFIG_INTERVAL;

    emit ConfigChanged(newConfig);
  }

  // collect
  // cashes the claims earlier swaps left, redeems as much held fURM as the vault allows and burns the float above the
  // target (all of it once closed). Every swap settles the same way; this is for quiet hours and wind-down. Automator only
  function collect() external nonReentrant {
    require(msg.sender == getAutomator(), "auth");
    settleFromOutside();
    burnExcess();
  }

  // closeTower
  // terminal wind-down: refuses swaps from now on, cashes the claims, redeems what the vault allows and burns the whole
  // float. fURM the window did not let through is redeemed and burned by later syncs. Either owner; one-shot
  function closeTower() external nonReentrant {
    (address owner1, address owner2) = getOwners();
    require(msg.sender == owner1 || msg.sender == owner2, "auth");
    require(!STATE.closed, "closed");

    STATE.closed = true;
    settleFromOutside();
    uint256 urmBurned = burnExcess();
    emit TowerClosed(urmBurned);
  }

  // getState
  // full read-only snapshot of the hook for off-chain monitoring and for integrators quoting before they swap (the
  // unwrap ceiling includes the vault's shared withdrawal window, so it moves with other holders' exits)
  function getState() external view returns (TowerStructs.FountainHookGetState memory) {
    (uint256 urmClaims, uint256 furmClaims) = getClaims();
    uint256 held = calcHeld(urmClaims, furmClaims);
    uint256 shortfall = calcShortfall(held);
    (address owner1, address owner2) = getOwners();

    return TowerStructs.FountainHookGetState({
      version: VERSION,
      automator: getAutomator(),
      owner1: owner1,
      owner2: owner2,
      multisig: UDO.getMultisig(),
      poolManager: address(poolManager),
      fountain: address(FOUNTAIN),
      urm: address(URM),
      wrapZeroForOne: wrapZeroForOne,
      urmBalance: getUrmBalance(),
      furmBalance: getFurmBalance(),
      urmClaims: urmClaims,
      furmClaims: furmClaims,
      urmHeld: held,
      urmShortfall: shortfall,
      syncRequested: calcSyncRequested(shortfall > 0),
      nextSyncAt: STATE.lastSync + CONFIG.syncInterval,
      floatReserve: calcReserve(),
      furmBacklog: calcBacklog(),
      urmPayable: calcPayable(),
      maxWrapUrm: calcMaxWrap(),
      maxUnwrapUrm: calcMaxUnwrap(),
      wrapShares: FOUNTAIN.previewDeposit(1e18),
      unwrapAssets: FOUNTAIN.previewRedeem(1e18),
      state: STATE,
      config: CONFIG
    });
  }

  // fortressData
  // reports as urmStored the URM float: the hook's balance plus its URM claims still in the PoolManager. fURM is not
  // reported: it stands for URM already inside the vault, which the Fountain reports itself
  function fortressData() external view returns (uint256 usdcPooled, uint256 usdcStored, uint256 urmPooled, uint256 urmStored, uint256 urmBorrowed) {
    (uint256 urmClaims, ) = getClaims();
    return (0, 0, 0, getUrmBalance() + urmClaims, 0);
  }

  // fortressPreSync
  // asks the Fortress for what tops the float up to CONFIG.urmTarget, measured on URM, claims and fURM at redemption value
  // so a swap in flight is never requested twice. Syncs at once when URM would move, otherwise once per CONFIG.syncInterval
  // and only when the sync has work
  function fortressPreSync(uint256 urmRequestable) external view returns (bool syncRequested, uint256 urmRequested) {
    (uint256 urmClaims, uint256 furmClaims) = getClaims();
    uint256 shortfall = calcShortfall(calcHeld(urmClaims, furmClaims));
    urmRequested = shortfall < urmRequestable ? shortfall : urmRequestable;
    syncRequested = calcSyncRequested(urmRequested > 0);
  }

  // fortressSync
  // called by the Fortress after it transfers the requested URM: cashes the claims, redeems what the vault allows, burns
  // the float above the target (all of it once closed) and stamps the sync. Fortress or automator
  function fortressSync() external nonReentrant {
    require(msg.sender == URM_FORTRESS || msg.sender == getAutomator(), "auth");

    settleFromOutside();
    burnExcess();
    STATE.lastSync = block.timestamp;
    STATE.syncCount += 1;

    emit Synced(getUrmBalance(), getFurmBalance());
  }

  // unlockCallback
  // the unlock settleFromOutside opens; the PoolManager is the only caller
  function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
    settleInternal();
    return "";
  }

  // _deposit (BaseTokenWrapperHook)
  // wrap: settles what earlier swaps left, deposits the swap's URM from the float, hands the fURM to the pool and books the
  // URM the swapper is about to settle as a claim. The vault's limits propagate as reverts ("paused", "fund", "amt", "closed")
  function _deposit(uint256 underlyingAmount) internal override returns (uint256 actualUnderlyingAmount, uint256 wrappedAmount) {
    settleInternal();
    checkFloat(underlyingAmount);

    wrappedAmount = FOUNTAIN.deposit(underlyingAmount, address(this));
    actualUnderlyingAmount = underlyingAmount;
    _settle(wrapperCurrency, address(this), wrappedAmount);
    poolManager.mint(address(this), underlyingCurrency.toId(), underlyingAmount);

    STATE.totalWrapped += underlyingAmount;
    STATE.wrapCount += 1;
  }

  // _withdraw (BaseTokenWrapperHook)
  // unwrap: settles what earlier swaps left, pays the swapper from the float what the vault would pay for the fURM and
  // books the fURM as a claim, redeemed at a later settle. The payout plus the fURM still to redeem must fit the vault's
  // payable URM ("max"); "bal" when the float above the reserve cannot cover it
  function _withdraw(uint256 wrappedAmount) internal override returns (uint256 actualWrappedAmount, uint256 underlyingAmount) {
    settleInternal();
    underlyingAmount = FOUNTAIN.previewRedeem(wrappedAmount);
    require(underlyingAmount > 0, "amt");
    require(FOUNTAIN.previewRedeem(calcBacklog() + wrappedAmount) <= IFountainUrm(address(FOUNTAIN)).payableUrm(), "max");
    checkFloat(underlyingAmount);

    actualWrappedAmount = wrappedAmount;
    _settle(underlyingCurrency, address(this), underlyingAmount);
    poolManager.mint(address(this), wrapperCurrency.toId(), wrappedAmount);

    STATE.totalUnwrapped += underlyingAmount;
    STATE.unwrapCount += 1;
  }

  // _supportsExactOutput (BaseTokenWrapperHook)
  // exact input only, as Uniswap's own wstETH hook: above a share price of 1 an exact URM amount is not always reachable
  // with whole fURM, which would leave a delta the PoolManager refuses to close
  function _supportsExactOutput() internal pure override returns (bool) {
    return false;
  }

  // settleFromOutside
  // the settle for callers that are not inside a swap: opens an unlock so the claims can be cashed, the PoolManager
  // calls back into unlockCallback
  function settleFromOutside() internal {
    poolManager.unlock("");
  }

  // settleInternal
  // must run inside an unlock: cashes the claims earlier swaps left, then redeems as much held fURM as the vault allows
  function settleInternal() internal {
    sweepClaims();
    collectInternal();
  }

  // sweepClaims
  // cashes the hook's ERC-6909 claims into the float, up to what the PoolManager physically holds: a claim minted earlier
  // in the same unlock is not settled yet and waits for the next sweep instead of reverting the swap
  function sweepClaims() internal {
    (uint256 urmClaims, uint256 furmClaims) = getClaims();
    sweepClaim(underlyingCurrency, urmClaims, URM.balanceOf(address(poolManager)));
    sweepClaim(wrapperCurrency, furmClaims, FURM.balanceOf(address(poolManager)));
  }

  // sweepClaim
  // cashes `claims` of `currency`, or as much as the PoolManager holds (`held`)
  function sweepClaim(Currency currency, uint256 claims, uint256 held) internal {
    uint256 amount = claims < held ? claims : held;
    if (amount == 0) return;
    poolManager.burn(address(this), currency.toId(), amount);
    poolManager.take(currency, address(this), amount);
  }

  // collectInternal
  // redeems held fURM for URM up to what the vault allows right now (maxRedeem: its balance and the shared withdrawal
  // window). Nothing when the vault allows nothing
  function collectInternal() internal {
    uint256 held = getFurmBalance();
    if (held == 0) return;
    uint256 redeemable = FOUNTAIN.maxRedeem(address(this));
    if (redeemable > held) redeemable = held;
    if (redeemable == 0) return;

    uint256 urm = FOUNTAIN.redeem(redeemable, address(this), address(this));
    STATE.totalRedeemed += redeemable;
    emit Collected(redeemable, urm);
  }

  // burnExcess
  // burns the float above CONFIG.urmTarget, or all of it once closed: Fortress-minted URM the tower no longer needs is
  // retired, never sent to a wallet
  function burnExcess() internal returns (uint256 urmBurned) {
    uint256 balance = getUrmBalance();
    uint256 keep = STATE.closed ? 0 : CONFIG.urmTarget;
    if (balance <= keep) return 0;
    urmBurned = balance - keep;
    URM.burn(urmBurned);
    STATE.totalBurned += urmBurned;
    emit Burned(urmBurned);
  }

  // checkFloat
  // a swap may draw `needed` from the float only while the hook is open and the reserve stays intact: "closed" once
  // closed, "bal" when the float above the reserve cannot cover it
  function checkFloat(uint256 needed) internal view {
    require(!STATE.closed, "closed");
    require(getUrmBalance() >= needed + calcReserve(), "bal");
  }

  // calcSyncRequested
  // whether a sync should be requested: at once when URM would move (`funding`), otherwise once per CONFIG.syncInterval
  // and only when the sync has work: claims to sweep, fURM the vault would redeem now, or float to burn
  function calcSyncRequested(bool funding) internal view returns (bool) {
    if (funding) return true;
    if (block.timestamp < STATE.lastSync + CONFIG.syncInterval) return false;
    (uint256 urmClaims, uint256 furmClaims) = getClaims();
    if (urmClaims > 0 || furmClaims > 0) return true;
    if (getFurmBalance() > 0 && FOUNTAIN.maxRedeem(address(this)) > 0) return true;
    return getUrmBalance() > (STATE.closed ? 0 : CONFIG.urmTarget);
  }

  // calcHeld
  // everything the hook holds at redemption value: the URM float, the URM claims, and the held fURM plus fURM claims at
  // what the vault would pay for them now
  function calcHeld(uint256 urmClaims, uint256 furmClaims) internal view returns (uint256) {
    return getUrmBalance() + urmClaims + FOUNTAIN.previewRedeem(getFurmBalance() + furmClaims);
  }

  // calcShortfall
  // URM to ask the Fortress for: what tops `held` up to CONFIG.urmTarget, 0 when covered or once closed
  function calcShortfall(uint256 held) internal view returns (uint256) {
    if (STATE.closed || held >= CONFIG.urmTarget) return 0;
    return CONFIG.urmTarget - held;
  }

  // calcReserve
  // the float a swap may not draw below: CONFIG.minFloatPercent of CONFIG.urmTarget
  function calcReserve() internal view returns (uint256) {
    return CONFIG.urmTarget * CONFIG.minFloatPercent / PCT;
  }

  // calcAvailable
  // the float above the reserve: what a single swap may draw right now, 0 once closed
  function calcAvailable() internal view returns (uint256) {
    if (STATE.closed) return 0;
    uint256 balance = getUrmBalance();
    uint256 reserve = calcReserve();
    return balance > reserve ? balance - reserve : 0;
  }

  // calcMaxWrap
  // largest wrap right now: the float above the reserve, 0 while the vault refuses deposits or once closed
  function calcMaxWrap() internal view returns (uint256) {
    return FOUNTAIN.maxDeposit(address(this)) == 0 ? 0 : calcAvailable();
  }

  // calcBacklog
  // fURM the hook still has to redeem: what it holds plus its fURM claims. Unwraps are checked with it included, since the
  // vault's window is only consumed when the hook redeems
  function calcBacklog() internal view returns (uint256) {
    return getFurmBalance() + poolManager.balanceOf(address(this), wrapperCurrency.toId());
  }

  // calcPayable
  // the vault's payable URM still free for a new unwrap: what it can pay right now less what the fURM still to redeem
  // will take of it
  function calcPayable() internal view returns (uint256) {
    uint256 payable_ = IFountainUrm(address(FOUNTAIN)).payableUrm();
    uint256 backlog = FOUNTAIN.previewRedeem(calcBacklog());
    return payable_ > backlog ? payable_ - backlog : 0;
  }

  // calcMaxUnwrap
  // largest unwrap payout right now: the float above the reserve, capped by the vault's payable URM less what the fURM
  // still to redeem will take of it
  function calcMaxUnwrap() internal view returns (uint256) {
    uint256 payable_ = calcPayable();
    uint256 available = calcAvailable();
    return available < payable_ ? available : payable_;
  }

  // getClaims
  // the hook's ERC-6909 claims on the PoolManager, URM and fURM
  function getClaims() internal view returns (uint256 urmClaims, uint256 furmClaims) {
    urmClaims = poolManager.balanceOf(address(this), underlyingCurrency.toId());
    furmClaims = poolManager.balanceOf(address(this), wrapperCurrency.toId());
  }

  // getUrmBalance
  // raw URM held by the hook: the float
  function getUrmBalance() internal view returns (uint256) {
    return URM.balanceOf(address(this));
  }

  // getFurmBalance
  // raw fURM held by the hook, awaiting redemption
  function getFurmBalance() internal view returns (uint256) {
    return FURM.balanceOf(address(this));
  }

  // getAutomator
  function getAutomator() internal view returns (address) {
    return UDO.getAutomator();
  }

  // getOwners
  function getOwners() internal view returns (address, address) {
    return UDO.getOwners();
  }
}
