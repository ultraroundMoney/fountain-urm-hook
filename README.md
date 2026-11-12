# FountainUrmHook

A Uniswap v4 token-wrapper hook on Base. It lets anyone wrap URM into fURM, and unwrap fURM back into URM, with an ordinary swap on a single v4 pool.

fURM is the share token of FountainUrm, an ERC-4626 vault whose asset is URM. The hook does not set a price of its own: every swap is priced by the vault's `previewDeposit` and `previewRedeem`.

## Deployment (Base, chain id 8453)

| Item | Value |
| --- | --- |
| Hook | [`0xE55A5e3d35Ad2B0bBe3A0bF9AD13De2599D2e888`](https://basescan.org/address/0xE55A5e3d35Ad2B0bBe3A0bF9AD13De2599D2e888) |
| Pool ID | `0x0d0904533688426e1cae710b10b92bcd126e80447f289537fc18e12c73df9508` |
| currency0 | fURM / FountainUrm vault, [`0x95fa3FA511Ef8DD9e48453eaE76b241D1c1AC651`](https://basescan.org/address/0x95fa3FA511Ef8DD9e48453eaE76b241D1c1AC651) |
| currency1 | URM, [`0xF0E3349f00972475a5D16721796091AA3B997837`](https://basescan.org/address/0xF0E3349f00972475a5D16721796091AA3B997837) |
| fee | `0` |
| tickSpacing | `60` |
| PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |

The pool was initialized at `sqrtPriceX96 = 2^96`. The pool price is never used.

## Hook permissions

The hook address carries the flags `0x2888`:

| Flag | Purpose |
| --- | --- |
| `beforeInitialize` | Accepts only the fURM/URM pair at fee 0. |
| `beforeAddLiquidity` | Always reverts (`LiquidityNotAllowed`). The pool holds no liquidity. |
| `beforeSwap` | Performs the wrap or unwrap. |
| `beforeSwapReturnDelta` | Returns the full swap delta, so the pool's own curve is bypassed. |

The contract extends Uniswap's `BaseTokenWrapperHook` from `@uniswap/v4-periphery`, the same base as Uniswap's WETH and wstETH wrapper hooks.

## How a swap works

A standard router settles the input token after the swap. A plain wrapper hook would need that input during `beforeSwap`, before it has been paid. This hook therefore keeps its own URM float and fronts every swap from it.

**Wrap (URM to fURM)**

1. The hook deposits the swap's URM amount into the vault from its float.
2. It hands the fURM it received to the PoolManager for the swapper.
3. It books the URM the swapper is about to pay as an ERC-6909 claim on the PoolManager.

**Unwrap (fURM to URM)**

1. The hook pays the swapper `previewRedeem(fURM in)` in URM from its float.
2. It books the fURM the swapper is about to pay as an ERC-6909 claim.

**Settlement.** At the start of every swap the hook cashes the claims left by earlier swaps and redeems the fURM it holds, as far as the vault allows. The float is restored that way. The same settlement runs on `fortressSync` and `collect`, so claims do not wait for the next swap during quiet periods.

## What routers and integrators need to know

- **Exact input only.** Exact-output swaps revert with `ExactOutputNotSupported`. Above a share price of 1, an exact URM amount is not always reachable with a whole number of fURM wei.
- **No in-pool liquidity.** Pool TVL reads as zero. The available depth is the hook's URM float, 25,000 URM at deployment.
- **Quotes.** One URM in gives `vault.previewDeposit(amount)` fURM. One fURM in gives `vault.previewRedeem(amount)` URM. The vault's fees are already inside these numbers, and the hook adds none. The share price accrues every block, so a quote taken a block earlier can differ by a few wei.
- **Size limits.** Read `getState()` before quoting a large swap:
  - `maxWrapUrm` is the largest wrap right now, in URM.
  - `maxUnwrapUrm` is the largest unwrap payout right now, in URM. It is also capped by the vault's shared withdrawal window, so it moves when other holders exit.
- **Direction.** fURM is currency0, so `zeroForOne = false` wraps and `zeroForOne = true` unwraps. `getState().wrapZeroForOne` reports this.
- **Hook data.** None. Pass `0x`.
- **Gas.** About 340k for a wrap and 300k for an unwrap through the Universal Router.

Reverts from the hook reach the caller inside v4-core's `WrappedError`:

| Reason | Meaning |
| --- | --- |
| `bal` | The float above the reserve cannot cover the swap. |
| `max` | The unwrap exceeds what the vault can pay out right now. |
| `amt` | The amount is too small, or outside the vault's limits. |
| `closed` | The hook, or the vault, has been closed. |
| `paused`, `fund` | The vault is refusing deposits. |

## Where the float comes from

The hook is registered as a tower of the URM Fortress, the contract that issues URM. On each Fortress sync the hook asks for the URM needed to bring its holdings up to `urmTarget`. Its holdings are measured as its URM, its claims, and its fURM at redemption value, so a swap in flight is never requested twice. Any float above the target is burned at the next sync.

## Roles and trust

The hook is not upgradeable. It has no proxy, no `delegatecall` and no `selfdestruct`. The PoolManager, URM, the vault, the Fortress and the ownership contract are compile-time constants.

Roles are read from the UrmDualOwnership contract at `0x268B9Be506E7338a3461256cfe86BAE7205aA9bc`.

| Role | Can do |
| --- | --- |
| Automator | `setConfigs` within fixed bounds and with a 1-hour cooldown; `collect`; `fortressSync`; `withdrawToken` for stray tokens other than URM and fURM. |
| Either owner | `closeTower`, once. Swaps revert from then on and the whole float is burned. |
| Fortress | `fortressSync`. |

No role can withdraw URM or fURM from the hook. The only exits for the float are payouts to swappers, deposits into the vault, and burning.

`setConfigs` bounds:

| Parameter | Bounds | Default |
| --- | --- | --- |
| `urmTarget` | 0 to 1,000,000 URM | 25,000 URM |
| `minFloatPercent` | 0 to 50 | 10 |
| `syncInterval` | 15 minutes to 1 day | 6 hours |

A single swap can draw the float down to the reserve, which is `minFloatPercent` of `urmTarget`. With the defaults, the largest single swap is 22,500 URM.

## Repository layout

All files sit at the root of the repository.

| File | Content |
| --- | --- |
| `FountainUrmHook.sol` | The hook. |
| `TowerStructs.sol` | Config, state and `getState` structs, with field comments. |
| `IFountainUrmHook.sol` | Events and external functions beyond `IHooks`. |
| `IERC20.sol`, `IERC4626.sol`, `IFountainUrm.sol`, `IUrm.sol`, `IUrmDualOwnership.sol`, `IUrmFortressTower.sol` | Interfaces of the contracts the hook calls. |
| `ReentrancyGuard.sol` | The reentrancy guard. |

## Build

The hook imports `@uniswap/v4-core` (1.0.2) and `@uniswap/v4-periphery` (1.0.3) from npm, and the other files from its own folder.

Compiler settings: solc 0.8.26, optimizer 200 runs, `viaIR`, EVM version `cancun`.

The hook was deployed with CREATE2 through the deterministic deployment proxy at `0x4e59b44847b379578588920cA78FbF26c0B4956C`. The init code is the compiled bytecode with no constructor arguments, so the address depends on the exact sources and compiler settings above.

## License

MIT
