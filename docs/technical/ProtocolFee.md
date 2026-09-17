# Treasury share of the oracle auction fee

`ProtocolFeeOracleStablePairHook` adds an input-currency treasury share to `OracleStablePairHook`. It reallocates the existing auction fee budget rather than intentionally adding a surcharge. It requires a newly mined proxy address with both swap-return-delta flags. An existing proxy without those flags cannot upgrade to this implementation; existing pools would need migration to the new hook address.

## Configuration

Each initialized PoolId has a separate `ProtocolFeeConfig`:

| Field | Unit and behavior |
| --- | --- |
| `recipient` | Receives PoolManager ERC6909 claims in the input currency. Required when both rate fields are nonzero; cannot be this hook or PoolManager. |
| `protocolFeeShareBps` | Share of the auction fee, 0 to 10,000. For example, 1,000 means 10% of the fee, not 10% of trade volume. |
| `maxProtocolFeePips` | Maximum treasury rate relative to gross input, 0 to 999,999. One basis point is 100 pips. |

Either rate field being zero disables collection. There is no implicit positive default. `CONFIG_MANAGER_ROLE` can change this configuration and the recipient independently per pool. Changes emit `ProtocolFeeConfigured` and do not reset the auction, change `optimalFeeE6`, or alter the reference-price band. Already-earned claims remain with their original recipient. The initializer can set both policies atomically using `initializeOraclePoolWithProtocolFee`; the inherited ordinary oracle initialization leaves treasury fees disabled.

This treasury variant requires both pool tokens to expose at least 6 decimals. The requirement is enforced whenever a reader is first bound or replaced, including through inherited oracle initialization. Six decimals limits one raw token unit to one millionth of a token, but does not by itself bound that unit's economic value. The base oracle hook and adapter layer retain their broader decimal support.

The role can change the share up to 100% and the cap up to 99.9999%; there is no additional immutable economic ceiling or timelock in this implementation. Treat the configured role as trusted. Existing upgrade authority is unchanged.

## Calculation and rounding

Let `f` be the auction fee, `h = min(f * share, cap)` the desired treasury budget, `F` the aggregate original fee including any native Uniswap protocol fee, and `L` the aggregate pool fee after reducing its LP component. Rates below are fractions, not integer pips.

Choose `L >= (F - h) / (1 - h)`, rounding upward to a representable core fee. Treasury amounts round down:

- Exact input: `treasury = floor(grossInput * (F - L) / (1 - L))`.
- Exact output: `treasury = floor(actualPoolInput * (F - L) / (1 - F))`.

With no native fee, a 1% auction fee and a 10% treasury share target a 0.1% treasury charge and approximately 0.900901% LP fee on the remaining input. These are sequential fees; simply subtracting 0.1 percentage points from the LP rate would be incorrect.

The fraction collected never exceeds the configured share/cap. Integer pips can make collection smaller than the nominal share, including zero. Exact-input trades whose treasury amount rounds to zero retain the original LP fee and partial-fill behavior. A fee-bearing exact-output swap reverts with `ProtocolFeeBelowMinimum` when it consumes input but its treasury amount rounds to zero; this prevents the reduced LP fee from becoming an uncollected discount. Saturated 100% aggregate core fees are not split; core's existing exact-output restriction still applies. Uniswap's own protocol fee remains core-controlled and is composed into the calculation; its absolute proceeds can change because core processes input after the treasury deduction.

The continuous-price economics match the original fee budget. Do not promise byte-for-byte quote equality: core rounds every swap step, and changing the LP rate changes those roundings. Exact-output input differences can be amplified when the aggregate fee approaches 100%. Always quote actual execution, particularly for tiny amounts, low-decimal tokens, tick crossings and high auction fees.

## Quotes and partial fills

`getFee` still reports the original, unsplit auction fee. `getFeeSplit(key, direction)` returns the adjusted LP fee and original/adjusted aggregate pool rates. It is a rate preview, not an amount quote or execution guarantee. Tiny exact-input amounts may use the original LP fee when their treasury deduction rounds to zero.

Quote integrations must simulate the actual hook through PoolManager with the intended amount and price limit. For fee-bearing exact-input trades, the input deduction is specified before core execution. If core does not consume all remaining input, the hook reverts with `PartialExactInput(requestedInput, executableInput)`. PoolManager wraps this inside `CustomRevert.WrappedError`. The entire transaction rolls back, including claims and auction state.

A quote/router integration can:

1. Simulate the requested exact-input swap.
2. If it encounters that specific wrapped error, extract the executable-input hint.
3. If nonzero, reduce the submitted input to the hint and **simulate again**, with bounded retries. The hint is calculated from observed core input; it is not a guaranteed quote across rounding, changed policy, changed oracle data or changed pool state.
4. Submit the successfully simulated amount with normal slippage controls. If conditions change and it cannot fully execute, revert without charging a treasury fee.

This repository exposes and tests the error/retry flow; it does not modify an application router or deploy a quote service. Multi-hop routes must simulate the complete route. Do not catch all reverts as partial fills: stale/paused oracle failures and other errors must remain failures.

Exact-output treasury fees use actual consumed input, including when core partially fills. `ProtocolFeeBelowMinimum` is wrapped by PoolManager like other hook callback errors. A router promising an exact output must still enforce its own requested-output requirement and surface or handle that specific tiny-trade failure. Disabled collection and zero-fee trades remain free of treasury charges. No liquidity-removal permissions are enabled.

## Collection

The hook mints ERC6909 claims directly to the configured recipient through PoolManager, and emits `ProtocolFeeAccrued` with pool, recipient, currency and amount. It makes no token transfer to the treasury during a swap. Stock sales accrue stock-token claims; stock purchases accrue USDG claims. Claims aggregate by recipient and currency across pools; events provide the per-pool breakdown.

`ProtocolFeeClaims` is a small batch redemption helper deployed by the Robinhood script. From the recipient account:

1. Call `PoolManager.setOperator(claimsHelper, true)` to authorize burning that account's ERC6909 claims. This is not an ERC20 allowance.
2. Call `claimsHelper.withdraw(currencies)` to redeem balances to that same caller. Empty or duplicate entries with zero balances are skipped.
3. Optionally revoke the operator authorization afterward.

The helper cannot select a different owner or payout recipient. Another caller cannot redeem treasury-owned claims. Transfers can still fail if a token blocks transfers; claims persist when the redemption transaction reverts.

## Build and validation

Use `FOUNDRY_PROFILE=robinhood`. This profile retains Solidity 0.8.26, Cancun and legacy code generation, but uses 10,000 optimizer runs to keep the treasury implementation below EIP-170. The repository's general high-run profile can produce oversized bytecode for this variant. Runtime-size coverage is part of the tests.

Tests exercise actual PoolManager settlement, both directions and swap types, native protocol fees, tick crossings, full-fill rollback, quote-hint retry, fee bounds, role isolation, treasury claim redemption and deterministic deployment. Local verification is not a new mainnet fork rehearsal or a production audit. Deployment parameters must be selected explicitly before any broadcast.
