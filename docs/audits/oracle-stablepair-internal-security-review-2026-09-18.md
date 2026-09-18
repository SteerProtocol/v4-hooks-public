# Oracle StablePair internal security review

## Reviewed revision

- Branch: `feat/atlas-sqrt-price-reader`
- Commit: `f9de428ba87552140484603fb4450df8d3f0cf5f`
- Review date: 2026-09-18
- Result: no reportable security findings

## Scope

The review covered the contracts and deployment paths added for oracle-referenced StablePair markets:

- `OracleStablePairHook` and `ProtocolFeeOracleStablePairHook`
- Atlas, Chainlink, Robinhood, and ERC-7726 price adapters
- `SqrtPriceReader`, price-ratio conversion, and dynamic-fee math
- Protocol-fee splitting, PoolManager return deltas, ERC6909 claim accrual, and claim redemption
- Role separation, UUPS upgrade checks, storage namespaces, and hook permission flags
- Robinhood market catalog validation, deterministic deployment, and rerun behavior
- Supporting stable-hook contracts and directly associated tests

## Result

No exploitable issue survived source validation. The review specifically rechecked the two earlier protocol-fee concerns:

1. Fee-bearing exact-input swaps that cannot consume their full adjusted input revert and roll back all state, including treasury claims.
2. Fee-bearing exact-output swaps calculate treasury accrual from actual pool input and revert when a configured split would round to zero, preventing a reduced LP fee from becoming an uncollected discount.

Callback entry points remain restricted to the immutable PoolManager. Reader binding and replacement require the configured role, contract code, exact token ordering, and a valid current reference price. Claim withdrawal binds the claim owner and payout recipient to the caller and relies on that owner's explicit PoolManager operator approval.

## Validation

The isolated StablePair test run completed with 213 passing tests, 0 failures, and 0 skips. It included:

- actual PoolManager settlement for both swap directions and exact-input and exact-output modes
- protocol-fee share and cap fuzzing
- native Uniswap protocol-fee composition
- partial-fill rollback and quote retry behavior
- sub-unit rounding and minimum token-decimal enforcement
- oracle freshness, pause, timestamp-skew, sequencer, decimal, and pair-orientation checks
- full-width sqrt-price conversion fuzzing
- role and UUPS upgrade tests
- dynamic-fee invariants, including a 5,000-case swap invariant
- initialization and idempotent rerun coverage for all 35 Robinhood stock/USDG markets

The treasury implementation runtime remains 24,261 bytes under the Robinhood compiler profile, 315 bytes below the EIP-170 limit.

## Required operating constraints

These behaviors are explicit deployment and integration constraints:

- `CONFIG_MANAGER_ROLE` is economically trusted. It can replace readers and change auction and treasury policy.
- Protocol-fee pools require both tokens to report at least six decimals. Adapter scaling assumes token decimals remain stable after deployment.
- ERC-7726 does not expose timestamps. Its selected oracle must enforce freshness and reference-value semantics. The Robinhood deployment uses the guarded Chainlink adapter instead.
- Native Uniswap protocol-fee rates remain core controlled, but absolute proceeds can change because core processes input after the hook's treasury deduction.
- Fee-bearing exact-input swaps require full execution. Routers must simulate the actual hook, price limit, and tick crossings, then retry the specific partial-fill hint when appropriate.
- Robinhood freshness tolerances are explicit operator inputs. The published 24-hour feed heartbeat is not a safe default for an AMM.
- A broadcast spans multiple transactions. A feed can expire or pause during deployment, leaving a partial but deterministically recoverable deployment.
- Storage-layout compatibility remains an off-chain release check for each UUPS upgrade.
- The 315-byte EIP-170 margin is narrow. Recheck runtime size after contract or compiler changes.

## Review limitations

This review did not verify a production broadcast, deployed role addresses, final fee and freshness parameters, live pool state, or the economic profitability of the stock-market configuration. Those checks remain required before mainnet deployment and liquidity funding.
