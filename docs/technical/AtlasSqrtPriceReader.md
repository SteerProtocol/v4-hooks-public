# Atlas reference price reader

The Atlas reader now uses the shared [oracle price adapter layer](./PriceAdapters.md).

For new integrations, deploy `AtlasPriceAdapter` with the Atlas V3 resolver, ordered token pair and feed IDs, then deploy `SqrtPriceReader(adapter)`. Chainlink and ERC-7726 inputs use the same reader with their respective adapters.

`AtlasSqrtPriceReader` remains available as a convenience compatibility wrapper:

```solidity
AtlasSqrtPriceReader.ReferencePrice memory referencePrice = reader.read();
uint160 sqrtPriceX96 = referencePrice.sqrtPriceX96;
uint64 epoch = referencePrice.canonicalEpoch;
uint64 observedAt = referencePrice.observedAt;
uint64 validUntil = referencePrice.validUntil;
```

Its constructor still accepts `(resolver, token0, token1, feedId0, feedId1)`. Feed and token getters and the `read()` return ABI are preserved. Errors inherited from the adapter/base should be referenced by their declaring Solidity type.

Both feeds must price one whole token in a common denomination. The reader fetches both prices in one Atlas snapshot, accounts for token decimals, and returns the exact floored raw token1/token0 `sqrtPriceX96`. It rejects invalid or expired data and does not retain a last-good-price fallback. A quote token's market value is read explicitly rather than assumed to equal $1.

For an 18-decimal stock worth $200 and a 6-decimal quote token worth $1:

- Stock is token0: `sqrtPriceX96 = 1120455419495722798374638`.
- Stock is token1: `sqrtPriceX96 = 5602277097478613991873193822745817`.

This layer does not alter StablePair's reference, fee state or liquidity. Direct swap-time consumption still needs a separate hook integration with deliberate reference-transition handling. See the adapter guide for numeric limits, timestamp semantics, deployment requirements and tests.
