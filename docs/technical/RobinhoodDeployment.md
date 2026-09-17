# Robinhood stock/USDG deployment

The deployment creates a `ProtocolFeeOracleStablePairHook` ERC1967 proxy, a shared `ProtocolFeeClaims` redemption helper, one `RobinhoodPriceAdapter` and `SqrtPriceReader` per market, and initializes the corresponding Uniswap v4 pools. It does not deposit liquidity or deploy an ALM vault. The original `StablePairHook` remains available for static references.

## Official feed research, 2026-09-11

[Robinhood's asset API](https://api.robinhood.com/rhj/assets) listed 194 active stock/ETF tokens. Chainlink's Robinhood feed metadata matched 35 of them. Its [source configuration](https://github.com/smartcontractkit/documentation/blob/main/src/features/data/chains.ts) points to the [feed metadata JSON](https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json). `script/deploy/robinhood/markets.json` records the intersection and the 159 excluded symbols. It uses the published `proxyAddress`, not the underlying aggregator or secondary proxy.

All 35 token symbols, token decimals, feed descriptions, feed decimals and `oraclePaused()` flags were checked through RPC. The verification batch started at block 60,568,131, at 2026-09-11 21:17:36 UTC; metadata and flags were read over the following small RPC batches. All flags were false. USDG was verified as 6 decimals; stock tokens were 18 and feed answers 8. The PoolManager and canonical CREATE2 factory had deployed code. Deployment preflight repeats the metadata checks instead of trusting the snapshot.

| Contract | Robinhood mainnet address |
| --- | --- |
| Chain ID | 4663 |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| USDG/USD feed | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` |

The PoolManager is from [Uniswap's deployment registry](https://developers.uniswap.org/docs/protocols/v4/deployments); USDG is from [Robinhood's token registry](https://docs.robinhood.com/chain/contracts/). The USDG feed comes from the same Chainlink catalog as the stock feeds.

Covered markets, each against USDG: AAPL, AMD, AMZN, ASML, BABA, CLSK, COIN, CRCL, CRWV, DELL, EWY, GME, GOOGL, INTC, IONQ, META, MSFT, MSTR, MU, NBIS, NVDA, ORCL, PLTR, QQQ, RGTI, RKLB, SGOV, SLV, SNDK, SPCX, SPY, TSLA, TSM, USAR and USO. The catalog includes ETFs. HOOD is not included because no matching official feed was found.

## Price semantics and availability

[Robinhood's oracle documentation](https://docs.robinhood.com/chain/oracles-and-price-feeds/) and [Chainlink's provider documentation](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood) specify that the feed already includes the stock token's `uiMultiplier`. Applying it again would double-count corporate actions. The adapter uses stock/USD divided by USDG/USD, then accounts for currency ordering and ERC20/feed decimals before converting to sqrtPriceX96. USDG is not assumed to equal one dollar.

The Robinhood wrapper checks `oraclePaused()` on every read, even if the retained feed answer is recent. It propagates pause, stale, invalid-answer, timestamp-skew and underlying call failures. The generic Atlas, Chainlink and ERC-7726 adapters remain usable with the same reader interface. The wrapper also supports both tokens being stocks, although this deployment catalog is exclusively stock/USDG.

All 35 published feed configurations currently have a **0.5% deviation threshold and 86,400-second heartbeat**. These are feed publication settings, not suitable default AMM freshness tolerances. Snapshot ages ranged from 173 to 76,584 seconds; only one stock feed was at most 900 seconds old. A 15-minute maximum age therefore rejected 34 of 35 markets in this snapshot. A 24-hour tolerance would accept older reference prices and may expose LPs to substantial price lag. The deployment intentionally requires explicit freshness inputs rather than selecting a production policy.

These are 24/5 feeds where underlying sessions support it. They can hold their last answer outside sessions and have no off-hours heartbeat. Freshness enforcement does not implement a trading calendar: a last price remains eligible until its configured age expires. Swaps then revert until the feeds are fresh again. Do not interpret a callable aggregator as an open market.

[Chainlink's sequencer uptime catalog](https://docs.chain.link/data-feeds/l2-sequencer-feeds) does not currently list Robinhood and says coverage is no longer expanding. The deployment therefore has no invented sequencer feed. Optional `SEQUENCER_UPTIME_FEED` and `SEQUENCER_GRACE_PERIOD` inputs can enable a separately verified compatible feed. With both unset there is no sequencer recovery guard; price freshness alone is not equivalent protection.

## Hook behavior

`initializeOraclePool` binds a matching nonzero reader and uses its live price for both the initial pool price and fee reference in one transaction. The oracle variant rejects the ordinary unbound initialization path.

Both `getFee` and every swap read the oracle, including swaps using the same-block AMM cache. When the sqrt reference differs from the stored reference, fee calculation starts with reset auction state and a fresh AMM price. A preview simulates that reset in memory. A swap persists the new reference and fee state. A new oracle round with an identical sqrt price does not reset the auction. `feeConfig` exposes the last persisted reference; use the reader to inspect the current oracle reference before a swap.

Frequent reference changes can repeatedly restart the Dutch auction. This preserves the existing reset economics; it does not establish that those economics or the sample fee parameters are profitable for equities. The fee band remains separate from LP tick ranges, and liquidity still needs management. The treasury variant enables both swap-return-delta flags; remove-liquidity callbacks remain disabled. It requires at least 6 decimals for both pool tokens, which the checked 18-decimal stock tokens and 6-decimal USDG satisfy. Its independently configured capped fee share, exact-input full-fill requirement, tiny exact-output guard and quote/retry integration are described in [ProtocolFee.md](ProtocolFee.md).

`CONFIG_MANAGER_ROLE` can replace a pool's reader after validating its pair and live price. It cannot remove the reader and silently enable a static fallback. Generic reader adapters with unknown timestamps, such as ERC-7726, rely on their own freshness policy. The Robinhood deployment always uses the guarded Chainlink adapter.

## Local simulation

Initialize the repository's pinned dependencies before building. The `robinhood` Foundry profile uses Solidity 0.8.26, legacy code generation and Cancun, with 10,000 optimizer runs to keep the treasury implementation below EIP-170, while limiting sources, tests and scripts to this work.

Set these environment variables explicitly:

| Input | Meaning |
| --- | --- |
| `ROBINHOOD_RPC_URL` | Mainnet RPC, preferably an archive-capable provider for reproducible forks |
| `DEPLOYER` | Transaction sender; receives `POOL_INITIALIZER_ROLE` |
| `HOOK_ADMIN` | Proxy upgrade and role administrator |
| `CONFIG_MANAGER` | Auction, treasury configuration and reader administrator |
| `PROTOCOL_FEE_RECIPIENT` | Recipient of input-token ERC6909 treasury claims |
| `PROTOCOL_FEE_SHARE_BPS` | Treasury share of the auction fee, 0 to 10,000; 1,000 means 10% |
| `MAX_PROTOCOL_FEE_PIPS` | Treasury cap relative to gross input, 0 to 999,999; 100 means 1 basis point |
| `FEE_K` | Auction excess-fee retention per L2 block, Q24 integer, 1 to 16,777,215 |
| `OPTIMAL_FEE_E6` | Fee-band parameter, 0 to 10,000; 1,000 means 10 basis points |
| `TARGET_MULTIPLIER` | Auction target multiplier, 0 to 100 |
| `TICK_SPACING` | Pool tick spacing, 1 to 32,767; does not set LP position width |
| `MAX_STOCK_PRICE_AGE` | Maximum accepted stock price age in seconds |
| `MAX_USDG_PRICE_AGE` | Maximum accepted USDG price age in seconds |
| `MAX_TIMESTAMP_SKEW` | Maximum timestamp difference between the two feeds, in seconds |

Set either treasury rate to zero to disable collection explicitly. These treasury settings apply to every market in this deployment batch; subsequent per-pool changes use `setProtocolFeeConfig`.

Optional inputs: `MARKETS_FILE` defaults to `script/deploy/robinhood/markets.json`; `MARKET_START` defaults to 0 and `MARKET_END` to the catalog length, with end exclusive. These bounds support staged batches. Optional sequencer inputs must either both be absent/zero or both be configured. Preserve all deployment inputs to reproduce addresses.

Run from the repository root:

```sh
FOUNDRY_PROFILE=robinhood forge test

FOUNDRY_PROFILE=robinhood forge script \
  script/deploy/robinhood/DeployRobinhoodMarkets.s.sol:DeployRobinhoodMarkets \
  --rpc-url "$ROBINHOOD_RPC_URL" --sender "$DEPLOYER" \
  --skip-simulation --compute-units-per-second 100 --rpc-timeout 10 -vv
```

This command **does not broadcast**. Here `--skip-simulation` skips Foundry's second transaction-replay stage; the script itself still executes against the fork, validates live prices and initializes/verifies each pool in local state.

Robinhood's native `ArbSys` precompile exposes `0xfe` through `eth_getCode`, while its real `arbBlockNumber()` call succeeds on chain. A plain Foundry EVM executes that placeholder as INVALID. During local script execution, the script uses `vm.mockCall` to model just this selector with the fork block number when that exact placeholder is present. This lets the unmodified upstream `BlockNumberish` constructor detect ArbSys. The mock is a simulation cheatcode, never a broadcast transaction. Foundry's second replay drops the mock and produces unusable gas estimates, which is why the command skips that replay. The initial fork simulation is checked, but native precompile execution is not reproduced by it.

Factory calls have explicit gas budgets: 7,000,000 for the implementation, 600,000 for the proxy, 2,000,000 per adapter and 1,000,000 per reader and 1,000,000 for the shared claims helper. Each pool-initialization call also has a 1,000,000 gas budget, so the skipped replay cannot leave its transaction without a gas limit. These are transaction execution budgets, not measured costs. On chain the implementation calls the real native precompile. Revalidate budgets if contracts or compiler settings change.

 For a pinned rehearsal, add `--fork-block-number` with a block served by an archive-capable endpoint. The script validates the chain, contract presence, token/feed metadata and every selected live price before collecting deployment transactions. A stale or paused selected market fails the whole simulation; it is never silently dropped.

The script logs the implementation, proxy, proxy salt, PoolId, adapter and reader for each market. Its CREATE2 salts and initcode determine reproducible addresses. An identical rerun reuses the contracts and pools, checking implementation, required roles, reader identity, auction policy and treasury policy. Changed roles or policies can produce different addresses or a mismatch error, so a rerun is not a mechanism for modifying an existing deployment. Use the hook's authorized configuration functions for intentional updates.

A future broadcast requires explicit authorization, a wallet matching `DEPLOYER`, gas funding, reviewed admin/config-manager addresses, and selected fee/freshness parameters. Initialization grants no liquidity. After market creation, the administrator can revoke the deployer's initializer role if no further pool creation is desired; rerunning initialization would then require restoring or updating the authorized setup.

## Validation

On 2026-09-17, all 213 tests passed under `--isolate`, including the treasury split and complete catalog deployment tests. OpenZeppelin upgrades-core 1.46.0 validated `ProtocolFeeOracleStablePairHook` against `OracleStablePairHook` for storage compatibility, using the repository's existing constructor, immutable-variable and inherited-initializer allowances. This is a layout check only: the additional permission bits require a new proxy address, so the existing oracle-only proxy cannot upgrade in place. The treasury implementation runtime is 24,261 bytes under the Robinhood profile, below the 24,576-byte EIP-170 limit. The implementation is covered by the existing static-hook, upgrade, swap, fee-math, invariant and spreadsheet suites, plus oracle-specific integration/fuzz tests. The deployment tests use the complete checked-in catalog with mocked price sources and an actual local v4 PoolManager. They exercise all markets, identical reruns, wrong-chain rejection, decimal eligibility, and rejection of a paused or stale final market before any deployment broadcast call.

The full live-data fork script completed for all 35 markets, for the earlier oracle-only hook, preparing 107 unsigned transactions: 72 CREATE2 deployments (implementation, proxy, 35 adapters and 35 readers) plus 35 pool initializations. This used the simulation-only ArbSys response and skipped Foundry's unsupported second replay, as described above. The rehearsal used placeholder role addresses, k=16,609,443, optimalFeeE6=1,000, targetMultiplier=50, tickSpacing=60, and age/skew limits of 86,460 seconds. Those broad age bounds demonstrate deployment mechanics; they are not a selected production freshness policy.

That rehearsal predates the treasury variant. The current full catalog plan adds one claims-helper deployment, for 108 transactions on a fresh deployment, and requires a new fork rehearsal before broadcasting.

A broadcast is a sequence of transactions, not one atomic operation. A feed can expire or pause after preflight, leaving some contracts or pools already created. Preserve inputs and use the deterministic rerun/batch interval after resolving the source condition. Do not add liquidity until the intended pool setup has been verified.

Live catalog verification establishes addresses and source metadata. Local tests and the fork rehearsal do not validate the economic suitability of the auction for stocks or establish production readiness. No mainnet transactions have been submitted by this work.
