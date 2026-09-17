# Oracle price adapters

The reference-price pipeline separates provider integration from Uniswap conversion:

```text
Atlas resolver / Chainlink feeds / ERC-7726 quote oracle
                         |
                   IPriceAdapter
           validated raw token1/token0 ratio
                         |
                  SqrtPriceReader
               reference sqrtPriceX96
```

The reader layer can be used independently or by `OracleStablePairHook`, which binds a reader per pool and refreshes its reference during fee calculation. The original `StablePairHook` retains static-reference behavior. See [Robinhood deployment](RobinhoodDeployment.md) for the oracle-backed variant, reset policy and stock/USDG catalog. No contracts have been deployed by this work.

## Common interface

Each adapter is immutable and bound to one address-ordered ERC-20 pair. Construct `SqrtPriceReader(adapter)` and call `read()` to receive:

```solidity
struct ReferencePrice {
    uint160 sqrtPriceX96;
    uint64 observedAt;
    uint64 validUntil;
    bytes32 updateId;
}
```

`IPriceAdapter.readPrice()` supplies a positive `numerator / denominator` ratio in **raw token1 units per raw token0 unit**, plus metadata. The shared reader performs the exact integer conversion:

```text
sqrtPriceX96 = floor(sqrt(numerator / denominator) * 2^96)
```

It enforces v4's `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)` bounds. StablePair may enforce tighter bounds to leave room for its fee band. Token addresses and feed mappings must match the pool. Feed selection must account for token redemption/share ratios; the adapters do not infer them.

The common interface is deliberately a rational price rather than an eight-decimal number: it avoids quantizing all providers to Atlas's scale. It is not itself an ERC-7726 implementation. The ERC-7726 adapter consumes that standard as one of the supported inputs.

`updateId` is an opaque, source-local identity. A changed identity does not imply a changed price, and IDs are not ordered or comparable across adapters. Both timestamps zero means unavailable metadata. The reader never substitutes the current block time for a missing observation time. With nonzero metadata it rejects future, malformed, or expired timestamps. The adapter remains responsible for its own source's validity guarantees.

Use a new adapter/reader deployment to change an immutable feed configuration or provider. `OracleStablePairHook` authorizes reader replacement through `CONFIG_MANAGER_ROLE` and has no automatic fallback.

## AtlasPriceAdapter

Constructor: resolver, token0, token1, feedId0, feedId1.

- Calls Atlas V3 `getPrices` for both feeds in a single canonical snapshot.
- Both feeds must price a whole token in the same denomination, such as USD.
- The common eight-decimal scale cancels. Token decimals are queried at deployment.
- Validates snapshot metadata, positive values and expiry, and propagates resolver failures.
- Preserves `observedAt` and `validUntil`; `updateId` is the canonical epoch encoded as `bytes32`.
- Does not assume a quote token such as USDC is worth $1.

`AtlasSqrtPriceReader` remains a convenience compatibility wrapper with its original constructor, getters, and `read()` return ABI, including `canonicalEpoch`. Internally it uses the adapter and shared conversion library. Inherited error declarations now live on the adapter/base types for Solidity source references. `AtlasPriceMath` is retained as a small compatibility entrypoint; its conversion delegates to `PriceRatioMath`.

## ChainlinkPriceAdapter

Constructor: token0, token1, `Config`:

| Field | Meaning |
| --- | --- |
| `feed0`, `feed1` | AggregatorV3 proxy feeds for the respective whole tokens, in a common denomination |
| `maxAge0`, `maxAge1` | Required positive age bounds in seconds, configured for each feed's heartbeat and application |
| `maxTimestampSkew` | Maximum difference between feed update times; zero requires matching timestamps |
| `sequencerUptimeFeed` | Optional network-specific Chainlink L2 sequencer feed; zero disables this guard |
| `sequencerGracePeriod` | Required positive recovery wait when an uptime feed is configured; zero otherwise |

The adapter reads `latestRoundData()` and `decimals()` from each proxy. It rejects nonpositive answers, missing rounds/timestamps, future timestamps, excessive age, and timestamp skew. `answeredInRound` is deprecated and is not used as a freshness condition. The ratio accounts for both feed-decimal and token-decimal differences without rounding.

The reported observation time is the older `updatedAt`; expiry is the earlier of the two `updatedAt + maxAge` values. `updateId` hashes the two round IDs. Chainlink feeds need not share an epoch; age and skew bounds control that distinction explicitly.

If configured, the sequencer guard rejects downtime, missing/future recovery timestamps, and the recovery grace period including its endpoint. Disabling it does not automatically make the adapter suitable for an L2 deployment. Feeds, heartbeat limits, market-hours policies and network-specific safeguards must be selected for the intended pool.

References: [AggregatorV3 API](https://docs.chain.link/data-feeds/api-reference), [sequencer uptime guidance](https://docs.chain.link/data-feeds/l2-sequencer-feeds).

## RobinhoodPriceAdapter

Extends the Chainlink adapter with `stock0` and `stock1` flags. Each flagged token must expose `oraclePaused()`; a paused token or a failed call rejects the read. At least one stock flag is required. Official Robinhood feeds already contain the corporate-action multiplier, so the adapter does not apply it again. See [Robinhood deployment](RobinhoodDeployment.md) for verified coverage and freshness limitations.

## ERC7726PriceAdapter

Constructor: oracle, token0, token1, baseAmount.

[ERC-7726 Common Quote Oracle](https://eips.ethereum.org/EIPS/eip-7726) is a **draft** standard. Its `getQuote(baseAmount, base, quote)` returns an amount in raw quote-token units, rounded down. The adapter calls `getQuote(baseAmount, token0, token1)` and returns `quoteAmount / baseAmount`; it does not apply token decimals again.

`baseAmount` is an immutable sampling amount in raw token0 units. Choose enough precision that flooring one quote-token unit is immaterial, while respecting the oracle's amount limits. A zero result is rejected, and source reverts propagate. This ratio has the source's quote-rounding error; the subsequent sqrt conversion is exact for the returned rational, not an assertion of exact underlying market value. Use a reference-value oracle, not a swap quote containing fees or price impact.

ERC-7726 does not expose observation timestamps, expiry or update IDs. All three metadata fields are therefore zero. The underlying oracle MUST enforce acceptable freshness and fail when it cannot provide a reliable reference. The adapter cannot add an independently verified maximum-age check through this interface. It provides no protection against a provider that silently returns stale quotes.

## Numeric limits and validation

The adapter layer and base oracle hook support token and Chainlink-feed decimal counts from 0 through 38; cached token decimals must not change. `ProtocolFeeOracleStablePairHook` applies a narrower pool policy and requires both tokens to expose at least 6 decimals. Inputs that cannot be represented as exact uint256 rational components after factor cancellation are rejected. No value is silently truncated to uint64. Native currency is unsupported; use wrapped ERC-20s.

`PriceRatioMath` handles full-width uint256 ratio components. It uses Q192 directly when possible, and an exact 320-bit quotient representation with integer Newton refinement for large ratios. Tests include independent Python integer vectors, 768-bit cross-multiplication checks, scaling cancellation, v4 boundaries, and the original Atlas regression properties.

With the repository's pinned dependencies installed, run the focused suite on Solidity 0.8.26:

```sh
FOUNDRY_SRC=src/stable/oracles FOUNDRY_TEST=test/stable/oracles \
FOUNDRY_SCRIPT=src/stable/oracles FOUNDRY_FFI=false \
forge test --use 0.8.26 -vv
```

The local validation used the same source/test files and compiler settings through an isolated Foundry root to avoid installing unrelated submodules. The original 39 adapter/math tests include 8,192 fuzz cases. The broader StablePair suite now includes oracle-hook and Robinhood deployment tests. Provider behavior in local tests uses mocks implementing production ABIs; live catalog checks and fork-rehearsal limits are documented in the Robinhood deployment guide.
