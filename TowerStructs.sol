// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// struct home for the FountainUrmHook tower; the vault's own structs live with it on branch urm-fountain
library TowerStructs {

  // FountainHookConfig: configurable parameters for the FountainUrmHook, adjustable by the automator
  struct FountainHookConfig {
    uint256 urmTarget;         // URM float the tower asks the Fortress to top it up to; the float above it is burned at the next sync or collect, 18 dec (0-1,000,000 URM; default 25,000)
    uint256 minFloatPercent;   // percent of urmTarget a swap may not draw the float below, kept as a reserve (0-50; default 10)
    uint256 syncInterval;      // least time between sync requests that only sweep claims, redeem fURM or burn float; a shortfall requests at once (900-86400; default 21600 = 6h)
  }

  // FountainHookState: internal state tracking for the FountainUrmHook
  struct FountainHookState {
    bool closed;               // true once closeTower has executed: swaps are refused and every sync redeems what it can and burns the URM
    uint256 nextConfigTime;    // earliest timestamp when setConfigs can be called again
    uint256 lastSync;          // timestamp of the last fortressSync
    uint256 syncCount;         // number of fortressSync calls
    uint256 totalWrapped;      // cumulative URM wrapped into fURM through the pool (18 dec)
    uint256 totalUnwrapped;    // cumulative URM paid out for fURM through the pool (18 dec)
    uint256 totalRedeemed;     // cumulative fURM the hook redeemed back into URM (18 dec)
    uint256 totalBurned;       // cumulative URM burned: float above urmTarget at sync or collect, everything at and after close (18 dec)
    uint256 wrapCount;         // number of wraps served
    uint256 unwrapCount;       // number of unwraps served
  }

  // FountainHookGetState: complete read-only snapshot of the FountainUrmHook returned by getState()
  struct FountainHookGetState {
    uint256 version;           // contract version identifier
    address automator;         // current automator address with config privileges
    address owner1;            // UDO owner 1 (closeTower is owner-gated)
    address owner2;            // UDO owner 2
    address multisig;          // UDO multisig, recipient of withdrawToken sweeps
    address poolManager;       // Uniswap v4 PoolManager
    address fountain;          // FountainUrm: the vault and the fURM token, the pool's wrapper currency
    address urm;               // URM, the pool's underlying currency
    bool wrapZeroForOne;       // true when URM is currency0 of the pool key, so a zeroForOne swap wraps URM into fURM
    uint256 urmBalance;        // URM the hook holds: the float swaps are fronted from (18 dec)
    uint256 furmBalance;       // fURM the hook holds, awaiting redemption within the vault's window (18 dec)
    uint256 urmClaims;         // URM settled by earlier wraps and still in the PoolManager as the hook's claims, swept at the next swap or sync (18 dec)
    uint256 furmClaims;        // fURM settled by earlier unwraps, held the same way (18 dec)
    uint256 urmHeld;           // all of the above at redemption value: what fortressPreSync measures against urmTarget (18 dec)
    uint256 urmShortfall;      // urmTarget - urmHeld, 0 when covered or once closed: what fortressPreSync asks the Fortress for (18 dec)
    bool syncRequested;        // whether fortressPreSync would ask for a sync now, assuming the Fortress can fund the request
    uint256 nextSyncAt;        // lastSync + syncInterval: the earliest a sync with work, but no shortfall, is requested
    uint256 floatReserve;      // urmTarget x minFloatPercent / 100: the float a swap may not draw below (18 dec)
    uint256 furmBacklog;       // fURM the hook still has to redeem: furmBalance + furmClaims (18 dec)
    uint256 urmPayable;        // the vault's payable URM still free for a new unwrap: its payableUrm less the backlog at redemption value, 0 when the backlog fills it (18 dec)
    uint256 maxWrapUrm;        // largest wrap right now: the float above the reserve, 0 while the vault refuses deposits or the hook is closed (18 dec)
    uint256 maxUnwrapUrm;      // largest unwrap payout right now: the float above the reserve, capped by the vault's payable URM less the fURM still awaiting redemption; 0 once closed (18 dec)
    uint256 wrapShares;        // previewDeposit(1e18): fURM received for 1 URM after the deposit fee (18 dec)
    uint256 unwrapAssets;      // previewRedeem(1e18): URM received for 1 fURM after the withdraw fee (18 dec)
    TowerStructs.FountainHookState state;   // current internal state
    TowerStructs.FountainHookConfig config; // current configuration
  }
}
