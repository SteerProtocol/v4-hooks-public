# Atlas reference price reader

`AtlasSqrtPriceReader` reads two Steer Atlas V3 feeds from one canonical snapshot and converts their ratio to Uniswap's `sqrtPriceX96`. It is a standalone view-only consumer. It does not modify `StablePairHook`, update fee configuration, reset fee state, or manage liquidity.

## Configuration and call

Deploy one reader with:

- The Atlas `MarketPriceResolverV3` address on the pool's chain.
- The pool's `token0` and `token1` addresses, already sorted in Uniswap address order.
- The corresponding `feedId0` and `feedId1`, each pricing one whole token in the same denomination, such as USD.

The constructor queries both tokens' decimals and stores the resolver, tokens, feed IDs, and decimals immutably. Supported token decimals are 0 through 38. Native currency is unsupported; use wrapped tokens. Tokens whose decimals change need a new reader.

```solidity
AtlasSqrtPriceReader.ReferencePrice memory referencePrice = reader.read();
uint160 sqrtPriceX96 = referencePrice.sqrtPriceX96;
uint64 epoch = referencePrice.canonicalEpoch;
uint64 observedAt = referencePrice.observedAt;
uint64 validUntil = referencePrice.validUntil;
```

Atlas `getPrices([feedId0, feedId1])` supplies both prices in the same canonical epoch, observation time, and validity window. Feed routing remains Atlas's responsibility. Resolver failures propagate, including unavailable or proof-only feeds. The consumer interface is an ABI-compatible subset of Atlas's Solidity 0.8.35 interface, allowing use in this repository's Solidity 0.8.26 compilation pipeline.

## Conversion

Atlas publishes both prices as eight-decimal positive integers. That common scale cancels:

```text
raw token1 per token0 = (price0 / price1) * 10^(decimals1 - decimals0)
sqrtPriceX96 = floor(sqrt(raw token1 per token0) * 2^96)
```

For a stock token with 18 decimals worth $200 and a quote token with 6 decimals worth $1:

- Stock is token0: `sqrtPriceX96 = 1120455419495722798374638`.
- Stock is token1: `sqrtPriceX96 = 5602277097478613991873193822745817`.

The quote-token price is read explicitly. The reader never assumes USDC equals $1. A feed for an underlying stock cannot automatically price a wrapper representing a different number of shares: feed selection must account for that relationship before using this reader.

`AtlasPriceMath` returns the exact integer floor. It uses a full-precision Q192 ratio where that fits. For larger ratios, a Q128 estimate followed by two integer Newton steps recovers the low bits without overflowing. Tests check the result against independent Python integer vectors and the defining squared-root inequalities.

## Read failures and integration boundary

The reader rejects missing epochs, zero/future observation timestamps, inverted or expired validity windows, malformed batch lengths, zero prices, and prices outside v4's `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)` interval. A read exactly at `validUntil` is accepted, matching Atlas. There is no cached fallback. Consumers may additionally impose their own maximum observation age.

These are v4 price bounds. StablePair configuration enforces narrower bounds that leave room for its fee band; passing this reader's validation alone does not guarantee that `updateFeeConfig` will accept an extreme reference.

An authorized updater can use the returned reference in StablePair's existing configuration setter. For direct swap-time consumption, a separate hook change must use this reader consistently in `getFee` and the swap path, enforce read failures there, and define reference-transition/reset behavior. Deploying this reader alone does not add those behaviors to StablePair.

The reader trusts the configured resolver and the chosen feed-to-token mapping. It does not establish source-market correctness, underlying/token redemption equivalence, market-hours policy, or live feed availability. No deployment addresses are embedded.

## Validation

Run the focused consumer suite with the existing remappings and Solidity 0.8.26:

```sh
FOUNDRY_SRC=src/stable/oracles FOUNDRY_TEST=test/stable/oracles \
FOUNDRY_SCRIPT=src/stable/oracles FOUNDRY_FFI=false \
forge test --use 0.8.26 --match-contract AtlasSqrtPriceReaderTest -vv
```

Tests cover both token orientations, mixed decimals, a quote-token depeg, epoch updates, expiry boundaries, malformed data, resolver failures, constructor validation, v4 bounds, independent exact vectors, and fuzz properties for exact rounding and common-scale invariance. They use a mock with the production Atlas batch ABI; live-chain resolver integration is a separate check.
