# VolumeTierFeeHook

A Uniswap v4 dynamic LP fee hook with no administrator, token, upgrade path, or asset custody.

Each PoolId has a UTC-aligned one-hour bucket (timestamp / 3600). The fee for a swap uses **previously completed swaps** in that bucket:

| Settled input volume | LP fee | v4 fee value |
| --- | --- | --- |
| Below 100 × 10^18 | 30 bps | 3000 |
| At least 100 × 10^18, below 1000 × 10^18 | 20 bps | 2000 |
| At least 1000 × 10^18 | 10 bps | 1000 |

The crossing swap pays the old tier; the following swap receives the discount. At the next hour boundary the fee immediately returns to 30 bps. Storage resets lazily on the next completed swap; use currentVolume/currentFee for current-hour reads, since the public buckets getter exposes the last stored bucket.

Volume is the actual negative input-side BalanceDelta, including fees: currency0 for zeroForOne, currency1 otherwise. Both directions contribute to one pool total. Exact-output and price-limited partial fills count actual input, never requested input or output. Failed transactions roll back accounting. PoolId includes the entire PoolKey, keeping different pools isolated. The accumulator saturates at uint256.max to preserve swap liveness.

## Assumptions and economics

Thresholds are fixed raw amounts, assuming **both currencies have 18 decimals**. There is deliberately no decimal lookup or price oracle. The sum is a nominal token count, not USD volume or a price-normalized metric; differently priced assets contribute equally per raw unit. Pools with other decimals can initialize but have different economic thresholds and should not use this configuration without review.

Busy does not imply organic demand: wash trades can buy a lower tier. Large trades do not obtain a discount until a subsequent trade. Block producers can influence ordering and timestamps around bucket boundaries. There is no rolling window, minimum fee revenue guarantee, or manipulation-resistant volume claim. Protocol fees, if configured by the manager, are separate from the hook's LP fee.

## Build and verify offline

Requires Foundry and the standard Solidity **0.8.26** compiler installed in its compiler cache; the compiler is pinned by version, never an executable path. Cancun EVM support is required for v4 transient storage.

    forge build --offline
    forge test --offline
    forge fmt --check

All Solidity dependencies are ordinary files under lib/, with exact upstream commit hashes recorded in dependencies.json. No dependency download, submodule, RPC, FFI, or filesystem cheatcode permission is needed. Vendored source subsets retain upstream licenses; v4-core includes the upstream CurrencySettler test helper. Tests were run with Forge 1.8.3.

Tests CREATE2-deploy the actual hook with valid permission bits, create a real vendored PoolManager, initialize pools, provide liquidity, settle swaps with PoolSwapTest, and remove liquidity with PoolModifyLiquidityTest. Coverage includes exact tier boundaries, applied fees from manager events, reset, both directions, exact output, partial fills, pool isolation, spoofed callbacks, static-pool rejection, transaction rollback, and fuzzed input accounting. Test currencies are upstream mocks only.

## Integration parameters and responsibilities

The sole constructor parameter is the canonical chain-specific IPoolManager address. The integrator must verify its chain, address and runtime implementation; zero is rejected, and the immutable manager cannot be replaced.

Mine a CREATE2 salt for the exact creation bytecode plus constructor argument so the hook address's low 14 bits equal **0x10c0 (4288)**: afterInitialize, beforeSwap, afterSwap. The constructor validates these permissions. HookFlags provides the standard bit definitions. No delta-return, donation, or liquidity permissions are enabled.

Initialize a sorted PoolKey with this hook, a valid tickSpacing and starting sqrtPriceX96, and fee exactly **LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000)**. afterInitialize rejects static-fee pools atomically. beforeSwap supplies the chosen fee with OVERRIDE_FEE_FLAG; the pool's stored dynamic fee is not the quote, so integrators should read currentFee and account for transaction ordering.

Every implemented callback checks msg.sender against the immutable manager. Neither sender nor hookData supplies identity or authorization. Unknown selectors revert. No router allowlist is needed. No hook callbacks gate LP additions or exits, and the hook neither transfers tokens nor changes settlement deltas. Exits remain subject to normal core settlement and underlying asset transfer behavior.

Pool creators are responsible for denomination suitability, initial price/liquidity, and supported token behavior. Routers/users are responsible for settlement and slippage limits. Operators should monitor realized fees, volume patterns, and bucket transitions. There are no keepers, owners, pause keys, emergency actions, or privileged update responsibilities. This repository supplies source and local tests only; no deployment transactions or launch artifacts. Tests are not an audit; independent adversarial review remains necessary before use with funds.
