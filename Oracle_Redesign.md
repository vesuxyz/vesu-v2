# Oracle Redesign — Vesu V2

Status: draft specification
Branch: `feat/oracle-redesign`

## 1. Motivation

The current V2 oracle (`src/oracle.cairo`, deployed at `0x00fe4bfb1b353ba51eb34dff963017f94af5a5cf8bdf3dfc191c504657f3c05`)
is a single contract hard-wired to Pragma. `Oracle::price(asset)` reads one `OracleConfig`
(`pragma_key`, `timeout`, `number_of_sources`, `start_time_offset`, `time_window`, `aggregation_mode`),
optionally computes a Pragma TWAP through the summary-stats contract, and returns
`AssetPrice { value: u256, is_valid: bool }`.

This document specifies a replacement that keeps the existing `IOracle` surface, adds Chainlink as a
first-class source, computes wrapper conversions on-chain, and prices assets through a small closed
set of source kinds implemented inside one router contract.

## 2. Design goals

- **Interface-compatible.** `IOracle::price(asset) -> AssetPrice` is unchanged. `pool.cairo` and
  everything downstream keep working untouched.
- **Read-only.** `price()` stays a view (`self: @TContractState`). The pool calls it from view
  functions (`position`, `check_collateralization`), so no validation rule may require a storage
  write or emit an event on the read path. Everything the monitoring stack needs is exposed as an
  additional view instead.
- **Non-reverting.** A failed, paused or stale source returns `is_valid: false`, never a revert.
  A revert is strictly worse than an invalid price: it blocks even repayment.
- **Liveness-preserving.** An invalid price freezes a market completely — `pool.cairo`'s
  `assert_security_invariants` runs on liquidations too, so `is_valid: false` blocks the liquidations
  that a bad price is supposed to protect against. Invalidate only when the price is genuinely
  _unknown_; express everything else as debt caps, pair config, or an operator pause.
- **Composable.** A price may be a ratio times the price of the asset that ratio is denominated in
  — an ERC-4626 conversion rate over its underlying, a pool ratio over its quote token, a
  non-USD-quoted feed over its quote asset. Composition is exactly one level deep, uses one rule for
  all three, and validates each leg independently.
- **Closed source set.** The router calls only the contracts named in a route, through interfaces
  fixed at compile time. There is no adapter registry and no arbitrary address in the price path, so
  a route change can repoint _which_ feed is read but never _what code_ runs. Adding a new source
  kind is an owner-gated upgrade (the EIC machinery `oracle.cairo` already has) — rarer than listing
  an asset, and reviewable in a way that registering an adapter is not.
- **Auditable per asset.** Every asset resolves to one route kind and one typed config entry.

## 3. Architecture

### 3.1 One router, four resolvers

```
                    ┌───────────────────────────────────┐
   pool.cairo ──►   │  OracleRouter                     │  implements IOracle
                    │  routes[asset] -> PriceRouteKind  │  no external adapters
                    └───┬───────┬───────────┬───────────┘
                        ▼       ▼           ▼
                  Chainlink   ERC-4626   Ekubo oracle
                  feed proxy  wrapper    extension
                  latest_     convert_   cumulative
                  round_data  to_assets  ticks

                  (+ Pragma oracle, spot only — legacy kind, §8 assets only)
```

Each kind is resolved by an internal function of the router against a source address held in that
asset's typed config. `Scaled` and `EkuboTwap` produce a _ratio_ rather than a USD price and are
therefore always composed with a quote leg, which the router resolves through its own terminal
resolver — so composition cannot recurse (§3.3).

Rationale for folding the resolvers in rather than deploying adapters: the pool reads two prices per
position update (`pool.cairo`, `context()`). An adapter indirection adds one external call per read
and two more for a composed route, which for an Endur-collateral position update is ~10 external
calls where today there are 2. The extensibility that indirection buys is already available through
the router's upgrade path, and an adapter address in the price path is an arbitrary-code hole that a
typed config field is not.

### 3.2 Route configuration

```cairo
#[derive(Copy, Drop, PartialEq, Serde, starknet::Store)]
pub enum PriceRouteKind {
    None,        // unconfigured, or deactivated (§7) — prices { value: 0, is_valid: false }
    Chainlink,   // direct feed
    Scaled,      // base leg × on-chain ERC-4626 conversion rate
    EkuboTwap,   // geomean TWAP from the Ekubo oracle extension, quoted in another asset
    Pragma,      // legacy path, retained for the assets in §8
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct ChainlinkConfig {
    pub feed: ContractAddress,        // aggregator proxy
    pub feed_decimals: u8,            // cached at config time from decimals(); <= MAX_DECIMALS (§3.5)
    pub max_staleness: u64,           // [seconds] 0 = disabled
    pub quote_asset: ContractAddress, // 0 = the feed is USD-quoted and this route is terminal;
                                      // otherwise the asset the feed is denominated in, composed
                                      // per §3.3 — e.g. a future wstETH/ETH feed (§8)
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct ScaledConfig {
    pub base_asset: ContractAddress, // asset supplying the base price; resolved non-composably
    pub wrapper: ContractAddress,    // ERC-4626-shaped share token; MUST equal the routed asset
    pub share_decimals: u8,          // cached at config time; <= MAX_DECIMALS (§3.5)
    pub underlying_decimals: u8,     // cached at config time — the divisor in §3.3
    pub ref_rate: u128,              // [SCALE] anchor rate, >= SCALE at config time, <= max_rate
    pub ref_timestamp: u64,          // [seconds] when the anchor was taken
    pub max_growth_per_second: u128, // [SCALE/second] slope of the upper bound; MUST be non-zero
    pub min_rate_ratio: u128,        // [SCALE] lower bound as a fraction of ref_rate
    pub max_rate: u128,              // [SCALE] absolute ceiling
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct EkuboConfig {
    pub oracle_extension: ContractAddress,
    pub quote_asset: ContractAddress,  // the pool's other token; MUST be non-zero — a pool ratio is
                                       // never a USD price, so there is no terminal Ekubo route
    pub base_decimals: u8,             // cached; decimals of the priced token; <= MAX_DECIMALS (§3.5)
    pub quote_decimals: u8,            // cached; needed to normalise the tick ratio to SCALE
    pub window: u64,                   // [seconds] >= MIN_TWAP_WINDOW
    pub max_spot_deviation: u128,      // [SCALE] advisory bound, reported by view, never invalidating
}
```

`OracleRouter` storage:

```cairo
routes: Map<ContractAddress, PriceRouteKind>,
chainlink_configs: Map<ContractAddress, ChainlinkConfig>,
scaled_configs: Map<ContractAddress, ScaledConfig>,
ekubo_configs: Map<ContractAddress, EkuboConfig>,
pragma_configs: Map<ContractAddress, OracleConfig>,   // unchanged struct from oracle.cairo
```

plus the manager/owner two-step pattern already used in `oracle.cairo` and the same `upgrade`/EIC
machinery. Per-kind maps are used instead of one union struct because the union's dead fields
(`base_asset` for a Chainlink route, `wrapper` for an Ekubo route) cost storage on every asset and
make the config unreadable — each kind stores exactly its own parameters.

Decimals are cached at configuration time rather than read on every price call: they are immutable
in practice, the config-time read validates that the source answers at all, and it removes one
external call from every price read. Every cached value is bounded by `MAX_DECIMALS` (§3.5).

`wrapper` must equal the routed asset. The field is kept for readability of the config, but letting
the two differ is a degree of freedom with no use and a configuration error that would silently price
one token off another token's rate.

### 3.3 Composition and the quote leg

Three of the four kinds produce a **ratio denominated in some other asset**, not a USD price. They
share one composition rule:

```
price(asset) = ratio(asset) × price_terminal(quote_asset) / SCALE
```

| Kind                    | `ratio(asset)`                                                                                                                          | `quote_asset`                                                 |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Chainlink, USD feed     | the feed answer, scaled                                                                                                                 | 0 — terminal, no second leg                                   |
| Chainlink, non-USD feed | the feed answer, scaled                                                                                                                 | the asset the feed quotes in (e.g. ETH for a wstETH/ETH feed) |
| Scaled                  | `convert_to_assets(10^share_decimals) × SCALE / 10^underlying_decimals`                                                                 | the underlying, i.e. `base_asset`                             |
| EkuboTwap               | geometric-mean pool ratio over the window, normalised to SCALE using the cached token decimals (in one full-width `mul_div`, see below) | the pool's other token                                        |
| Pragma                  | the aggregated USD **spot** answer, scaled                                                                                              | 0 — terminal, USD keys only                                   |

The Ekubo normalisation is a **single** `u256_mul_div(price_x128, SCALE x 10^base_decimals,
2^128 x 10^quote_decimals)`. Truncating the `2^128` ratio to SCALE first and adjusting for decimals
afterwards caps the relative precision at `1 / (price x 10^quote_decimals / 10^base_decimals)`, which
for an 18-decimal token quoted against a 6-decimal one costs a third of a percent at the low end of
the price range. `MAX_DECIMALS` (§3.5) is what keeps the one-step form inside `u256`.

`convert_to_assets(10^share_decimals)` is denominated in **underlying** units, so the normalising
divisor is `10^underlying_decimals`. (Every wrapper in §4.3 happens to have matching share and
underlying decimals today, which would hide a `10^share_decimals` divisor until the first wrapper
where they differ.)

Validity is the AND of both legs:

```
is_valid = ratio_is_valid && quote.is_valid && value != 0
```

**Each leg is validated by its own rules, against its own parameters.** This is worth spelling out,
because the two legs are checked by entirely different code and nothing about the composite's own
config constrains its quote leg:

| Leg                | Checked by                                      | Checks applied                                                                                                                                                                         |
| ------------------ | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ratio, `Chainlink` | `chainlink_ratio` with the _composite's_ config | read succeeded, deserialised, `answer != 0`, `updated_at != 0`, age ≤ **its own** `max_staleness`, scaled ratio `!= 0`                                                                 |
| ratio, `Scaled`    | `conversion_rate_of`                            | read succeeded, deserialised, rate `!= 0`, rate inside **its own** cone (§6.3)                                                                                                         |
| ratio, `EkuboTwap` | `ekubo_ratio`                                   | both reads succeeded, pair is tracked (`Some`), sufficient history for **its own** `window`, ratio `!= 0`                                                                              |
| quote              | `price_terminal(quote_asset)`                   | the quote asset's **own full check set**, for whatever terminal kind it is — a USD Chainlink feed with its own `max_staleness`, or Pragma with its own `timeout` / `number_of_sources` |

So a composed `Chainlink` route carries two independent staleness bounds: its own on the ratio feed, and
the quote asset's on the quote feed. wstETH is the live case — a 90000s bound on `WSTETH/ETH` (§6.2) over
a 3600s bound on `ETH/USD` — and neither inherits from the other. A deactivated quote asset (§7) prices
`{0, false}`, so every composite standing on it goes invalid too.

One subtlety that follows from §6.1 rather than contradicting it: a **stale** leg still surfaces its last
value, so the composed `value` is non-zero while `is_valid` is false, exactly as for a direct feed. A leg
that **failed or answered zero** yields `value == 0`. What §3.3 forbids is neither of those — it is the
composed value ever being the _bare ratio_, i.e. a pool ratio or an exchange rate escaping as if it were
a USD price.

**There is no unquoted fallback.** For `Scaled` and `EkuboTwap` a zero, unconfigured, or invalid
`quote_asset` yields `is_valid: false` — the router never returns the bare ratio. Returning an
EKUBO/ETH ratio where the pool expects a USD price would misprice the asset by three orders of
magnitude and report it as valid, which is worse than any outage. A zero `quote_asset` is therefore
rejected at configuration time for both kinds, and is meaningful only for a Chainlink or Pragma route
where the source itself is denominated in USD.

Note that an Ekubo pool quoted against a stable (say EKUBO/USDC) is _not_ an exception: its quote leg
is USDC, whose own route supplies USDC/USD. The composition is uniform; there is no special case.

### Why the quote leg should be the asset the pair borrows

Composition is not only about getting the units right. When a position's **collateral and debt share a
quote leg**, that leg cancels out of the loan-to-value ratio entirely, and solvency becomes a function
of the exchange rate alone:

```
collateral_value / debt_value = (rate x P) / P = rate
```

This is the decisive argument for routing wstETH through `ETH` rather than through a hypothetical
`wstETH/USD` feed, and for routing each Endur wrapper through **its own underlying**:

- A wstETH-collateral / ETH-debt position — the canonical LST leverage trade — stays exactly as solvent
  whether ETH is at \$100 or \$100,000. It moves only when the wstETH/ETH exchange rate moves, which is
  the only risk the position is actually taking.
- An xWBTC / WBTC position is likewise invariant to BTC/USD and sensitive only to the ERC-4626
  conversion rate.

Routing those assets to independent USD sources would reintroduce basis between the two legs, and a
position at 90% LTV would become liquidatable on a move in a price it has no exposure to.

This is asserted entirely against **real positions in the deployed `Prime` pool** (Appendix A). `Prime`
is repointed at the router with `set_oracle` as its curator — literally §10 step 8 — and every verdict
comes out of the pool's own `check_collateralization`, judged against `Prime`'s own `max_ltv` for the
pair. No synthetic positions, and no reimplementation of the solvency formula.

| Position     | LTV   | `Prime` max_ltv | asserted                                                                                                                                                                                                                      |
| ------------ | ----- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| wstETH / ETH | 80.5% | 91%             | invariant across five orders of magnitude of ETH/USD; a 20% rate fall raises the LTV by exactly 25% and puts it under water; and it flips **exactly** at the rate the pool's own numbers predict, one basis point either side |
| xSTRK / STRK | 83.0% | 90%             | invariant across eight orders of magnitude of STRK/USD                                                                                                                                                                        |
| xWBTC / WBTC | 70.8% | 90%             | invariant across eight orders of magnitude of BTC/USD                                                                                                                                                                         |

The edge case is the interesting one. A position at LTV `L` with limit `M` must flip exactly when the
exchange rate falls to `L / M` of its current value, because the LTV scales inversely with the rate and
nothing else in the pair moves. `test_fork_prime_wsteth_position_flips_exactly_at_its_rate_limit` derives
that factor from the pool's own `L` and `M` and asserts the verdict lands on opposite sides one basis
point either side of it — so the invariance above is not merely "nothing happened", it is "nothing
happened, and here is precisely what does".

These also measure position-level shadow parity: swapping Pragma for the router moves a real position's
LTV by under 100 bps.

One direction cannot be done against a live pool: dropping an ERC-4626 wrapper's **conversion rate**,
since the rate comes from the deployed wrapper rather than from a feed. That is covered in the mock
suite against the real `Pool` contract with a funded position and mocked sources
(`test_pool_wrapper_position_solvency_tracks_the_conversion_rate`). The wstETH case above covers the
same direction on a real position, because wstETH's rate _is_ a feed.

**This is the mirror image of §4.4's warning, not a contradiction of it.** A wrapper against _its own_
underlying is price-invariant by construction and that is desirable. §4.4's concern is a wrapper against
a _different_ wrapper — WBTC collateral against LBTC debt — where invariance means a depeg between two
genuinely distinct assets produces no oracle response at all. Same mechanism, opposite sign, and which
one you get depends entirely on whether the pair's two assets share real economic exposure.

**Depth is exactly one composition, by construction.** The quote leg is resolved by
`price_terminal()`, which handles only the two terminal kinds — `Chainlink` with `quote_asset == 0`
and `Pragma` — and returns `is_valid: false` for anything else. A configuration mistake therefore
degrades one asset instead of creating a cycle that reverts every price call in every pool through
out-of-gas. Config-time assertions on `quote_asset` are still made, but they are usability checks,
not the safety mechanism: the quote asset's own route can be changed afterwards, so the safety has
to be structural.

The deliberate cost of that rule is that a ratio cannot stack on a ratio — an ERC-4626 wrapper over
an Ekubo-priced token, or over another wrapper, has no route. No such asset is listed today. If one
is ever needed, raise the depth explicitly with a bounded loop and an iteration cap, in an upgrade
that can be reviewed on its own; do not relax the terminal set.

### 3.4 Failure isolation

The non-reverting guarantee is not free, and it constrains the implementation:

- Every source read on the price path goes through `call_contract_syscall` with the `SyscallResult`
  matched explicitly — **not** through a generated dispatcher. A dispatcher propagates the callee's
  panic and reverts the entire pool interaction; a paused feed proxy or a wrapper that starts
  reverting would block repayment and liquidation on every market listing that asset.
- The returned `Span<felt252>` is deserialised defensively. Wrong length, or a value that fails to
  fit its target type, yields `is_valid: false` rather than a panic.
- This applies to Chainlink `latest_round_data`, ERC-4626 `convert_to_assets`, the Ekubo extension
  reads, and the legacy Pragma `get_data` call.
- Configuration-time reads (`decimals()`, the initial `convert_to_assets` anchor) may use ordinary
  dispatchers and are allowed to revert. A manager transaction failing loudly is correct.
- Residual limits. Gas consumed by a failing call is not recovered, and an out-of-gas condition in a
  nested call cannot be caught, so per-read work must stay bounded — one more reason the router has
  no open-ended adapter call and composition is capped at one level. A call to an address with **no
  class deployed** is likewise unrecoverable: it fails the transaction rather than the syscall. A
  contract that exists but lacks the entrypoint, panics, or answers with a malformed payload _is_
  recoverable and degrades to `is_valid: false`. The undeployed-address case is therefore handled at
  write time instead: **every source named in a route is read once during configuration**, so an
  address with no class cannot enter a route. Per kind that is the feed's `decimals()`; the wrapper's
  `asset()`, `decimals()` and initial `convert_to_assets`; and — because an Ekubo route's cached
  decimals come from the _tokens_ rather than from the extension — an explicit
  `get_earliest_observation_time` probe of the oracle extension. A zero answer there is a legitimate
  state (no observations yet) and is not asserted on; the probe exists only to establish that the
  address answers at all.

### 3.5 The decimals bound

Every `pow_10` argument on the price path is a `decimals` value reported by a source, and `10^n`
overflows `u256` for `n >= 78`. An overflow there is a _panic inside `price()`_ — the one failure
mode §3.4 exists to prevent, and one that no amount of `safe_call` discipline catches, because the
exponentiation happens in the router's own arithmetic rather than in the callee.

`MAX_DECIMALS = 30` bounds every such exponent:

- Cached decimals (`feed_decimals`, `share_decimals`, `underlying_decimals`, `base_decimals`,
  `quote_decimals`) are asserted at configuration time, so an out-of-range source cannot enter a
  route at all.
- The `decimals` a **Pragma response carries** is bounded at _read_ time. This is the one exponent no
  configuration-time check can reach: it arrives with the response, so a Pragma contract answering out
  of range must degrade to `is_valid: false` rather than revert.

30 is far above any real token or feed (18 is the practical maximum) and low enough that the Ekubo
normalisation's `2^128 x 10^quote_decimals` and `SCALE x 10^base_decimals` both stay inside `u256`.

## 4. Source assignment

### 4.1 Chainlink feeds available on Starknet mainnet

Verified live at the §11 fork block. **Nine feeds, not seven** — and they are not all USD-quoted nor
all 8-decimal, which the first two rows below and the last two make concrete.

| Feed             | Proxy address                                                        | Deviation |
| ---------------- | -------------------------------------------------------------------- | --------- |
| BTC / USD        | `0x05a4930401bbb1d643ca501640e218fec253b33326f47d139bd025c62a1fbc7f` | 0.5%      |
| ETH / USD        | `0x06b2ef9b416ad0f996b2a8ac0dd771b1788196f51c96f5b000df2e47ac756d26` | 0.5%      |
| STRK / USD       | `0x076a0254cdadb59b86da3b5960bf8d73779cac88edc5ae587cab3cedf03226ec` | 0.5%      |
| USDC / USD       | `0x072495dbb867dd3c6373820694008f8a8bff7b41f7f7112245d687858b243470` | 0.3%      |
| USDT / USD       | `0x01cafc789a9b48f816fe0969c22667ea2d669e56274c806fc83a85215d42e988` | 0.3%      |
| DAI / USD        | `0x055d0eec2f5c766b3b8b696a43751ed4d56715fa26b0c50469d7855388f0c972` | 0.3%      |
| LINK / USD       | `0x015e0e153c086fadab9a9ed23630f79d8e265edf4747ef5b791f6db391e3f6fd` | 0.5%      |
| **WBTC / USD**   | `0x06275040a2913e2fe1a20bead3feb40694920a7fea98e956b042e082b9e1adad` | —         |
| **WSTETH / ETH** | `0x07ba92ee505a967f56253a5a51d8249c0515577fa9d1dea7f24e233ae3395184` | —         |

All nine answer `latest_round_data()` on the same interface, and all share one class hash
(`0x58c76a4d410272edf54033221efdbe5313b3744306847e17b3c4eb5597aebb8`). Two of them break assumptions
the rest of this document originally made:

- **WSTETH / ETH is 18-decimal and ETH-quoted.** Every other feed is 8-decimal and terminal. It is
  therefore the only live instance of §3.3's composed Chainlink route, and the only live check that
  `feed_decimals` is genuinely read from the feed — a hardcoded 8 would misprice wstETH by ten orders
  of magnitude and pass on every other asset.
- **WBTC / USD exists**, which makes parity pricing a choice for WBTC rather than a necessity (§4.4).

DAI and LINK are listed for completeness; no current V2 market uses them, and nothing routes to them,
so the fork suite deliberately excludes them — asserting on a feed no route reads would be testing
Chainlink rather than this router.

> **A warning about how this table is verified.** An earlier revision of this section claimed the set
> was closed at seven feeds, on the strength of
> `reference-data-directory.vercel.app/feeds-starknet-mainnet.json` plus an on-chain sweep for newly
> deployed aggregator proxies. **Both were wrong.** That JSON is stale and omits WBTC/USD and
> WSTETH/ETH; the sweep keyed on an access-control event that not every proxy emits. The reliable
> source is the rendered addresses page at
> `docs.chain.link/data-feeds/price-feeds/addresses?network=starknet`, whose embedded data lists all
> nine with `clicProductName` values of the form `<PAIR>-RefPrice-DF-Starknet-001`. Re-check there, not
> against the JSON, before concluding that a feed does not exist.

Read interface: `latest_round_data() -> Round { round_id, answer, block_num, started_at, updated_at }`,
plus `decimals()`. Note the heartbeat is a **staleness bound**, not an update cadence — updates fire
on whichever of deviation-or-heartbeat comes first, so flat-peg stablecoin feeds legitimately sit
close to 24h between updates. `max_staleness` must be set accordingly (§6.2).

An answer of zero, or a `updated_at` of zero (round never completed), is invalid.

**Resolved against the deployed ABI** (`ETH/USD` proxy, read at the fork block in §11): the aggregator
declares `chainlink::ocr2::aggregator::Round { round_id: felt252, answer: u128, block_num: u64,
started_at: u64, updated_at: u64 }`. `src/vendor/chainlink.cairo` matches that field-for-field, and
because `answer` is a `u128` rather than a signed type, a negative answer cannot be encoded at all —
the negative case does not arise. Should a future proxy change that, the `u128` deserialization fails
and the price is reported invalid rather than reverting (§3.4). Pinned by
`test_fork_chainlink_round_abi_matches_the_vendor_struct`.

### 4.2 Per-asset routing

| Asset     | Route     | Source                  | Notes                                                                                             |
| --------- | --------- | ----------------------- | ------------------------------------------------------------------------------------------------- |
| ETH       | Chainlink | ETH/USD                 | direct                                                                                            |
| USDC      | Chainlink | USDC/USD                | direct                                                                                            |
| USDC.e    | Chainlink | USDC/USD                | direct; bridged asset on the native feed — see §4.4                                               |
| USDT      | Chainlink | USDT/USD                | direct                                                                                            |
| STRK      | Chainlink | STRK/USD                | direct                                                                                            |
| WBTC      | Chainlink | BTC/USD **or WBTC/USD** | a dedicated feed exists; see §4.4 — this is the one parity row that is a choice                   |
| tBTC      | Chainlink | BTC/USD                 | wrapper priced at BTC parity                                                                      |
| LBTC      | Chainlink | BTC/USD                 | wrapper priced at BTC parity                                                                      |
| SolvBTC   | Chainlink | BTC/USD                 | wrapper priced at BTC parity                                                                      |
| strkBTC   | Chainlink | BTC/USD                 | wrapper priced at BTC parity                                                                      |
| uniBTC    | Chainlink | BTC/USD                 | wrapper priced at BTC parity                                                                      |
| YBTC.B    | Chainlink | BTC/USD                 | wrapper priced at BTC parity                                                                      |
| eBTC      | Chainlink | BTC/USD                 | wrapper priced at BTC parity; **10 decimals**, the only asset in the set that is neither 8 nor 18 |
| xWBTC     | Scaled    | BTC/USD × rate          | wrapper `0x06a567e68c805323525fe1649adb80b03cddf92c23d2629a6779f54192dffc13`                      |
| xLBTC     | Scaled    | BTC/USD × rate          | wrapper `0x07dd3c80de9fcc5545f0cb83678826819c79619ed7992cc06ff81fc67cd2efe0`                      |
| xsBTC     | Scaled    | BTC/USD × rate          | wrapper `0x0580f3dc564a7b82f21d40d404b3842d490ae7205e6ac07b1b7af2b4a5183dc9`                      |
| xtBTC     | Scaled    | BTC/USD × rate          | wrapper `0x043a35c1425a0125ef8c171f1a75c6f31ef8648edcc8324b55ce1917db3f9b91`                      |
| xstrkBTC  | Scaled    | BTC/USD × rate          | wrapper `0x047751b3532fabca89b0f2e35ca1cb45e5a7b11d5e3d3663dfa1f4406b45fd88`                      |
| xSTRK     | Scaled    | STRK/USD × rate         | wrapper `0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a`                      |
| EKUBO     | EkuboTwap | EKUBO/ETH × ETH/USD     | quote leg is mandatory, §3.3; parameters and cap in §5                                            |
| wstETH    | Chainlink | WSTETH/ETH × ETH/USD    | composed per §3.3, `quote_asset = ETH`; no longer TBD (§8)                                        |
| sUSN      | **TBD**   | —                       | §8                                                                                                |
| mRe7BTC   | **TBD**   | —                       | §8                                                                                                |
| mRe7YIELD | **TBD**   | —                       | §8                                                                                                |

The table above was reconciled against the deployed oracle's `SetOracleConfig` event history, which is
the authoritative list of what is actually listed — 24 assets. Two corrections came out of that, both
pinned by the fork suite (§11):

- **eBTC was missing.** It is listed against `BTC/USD` today and is the only 10-decimal asset in the
  set, which makes it the most useful single asset for catching a decimals error on the Chainlink leg.
- **Two USDC addresses are listed**, both on the `USDC/USD` key:
  `0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8` and
  `0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb`. These are the "USDC" and
  "USDC.e" rows. Both report the symbol `USDC` and both are 6-decimal, so they can only be told apart
  by address — worth care when writing the migration calldata.

### 4.3 Endur wrapper conversion rates

All Endur wrappers are ERC-4626-shaped. Verified on-chain (rates drift upward with accrual; the
figures below and the bands asserted in §11 were taken at different blocks, so the tests assert a band
and the relationship `price = rate x base`, never a snapshot):

| Wrapper  | Decimals | Underlying                                                                   | `convert_to_assets(1.0)` |
| -------- | -------- | ---------------------------------------------------------------------------- | ------------------------ |
| xSTRK    | 18       | STRK `0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d`    | 1.17881357               |
| xWBTC    | 8        | WBTC `0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac`    | 1.02732363               |
| xLBTC    | 8        | LBTC `0x036834a40984312f7f7de8d31e3f6305b325389eaeea5b1c0664b2fb936461a4`    | 1.02333474               |
| xsBTC    | 18       | SolvBTC `0x0593e034dda23eea82d2ba9a30960ed42cf4a01502cc2351dc9b9881f9931a68` | 1.02793236               |
| xtBTC    | 18       | tBTC `0x04daa17763b286d1e59b97c283c0b8c949994c361e426a28f743c67bdfe9a32f`    | 1.02746873               |
| xstrkBTC | 8        | strkBTC `0x0787150e306e6eae6e3f79dea881770e8bbff2c1b8eb490f969669ee945b3135` | 1.00718449               |

The router reads `convert_to_assets(10^share_decimals)` and normalises per §3.3. It MUST NOT use
`preview_redeem`, which may include withdrawal fees or queue effects and is therefore not a pure
exchange rate.

### 4.4 Where wrapper risk is priced

> **⚠️ Parity pricing carries no on-chain depeg signal.** Routing eight BTC wrappers to `BTC/USD`,
> and USDC.e to the native USDC feed, prices each at hard parity. A wrapper-vs-wrapper pair (WBTC
> collateral against LBTC debt) becomes exactly price-invariant, so a depeg converts straight into bad
> debt with no oracle response at all.
>
> **The "regression against today's per-asset Pragma keys" applies to WBTC only — and is avoidable.**
> Measured against the deployed oracle, WBTC is the one BTC wrapper with its own key (`WBTC/USD`);
> tBTC, LBTC, SolvBTC, strkBTC, uniBTC, YBTC.B and eBTC are _already_ on the shared `BTC/USD` key and
> so are already parity-priced today. So the only signal at risk is WBTC's basis against BTC.
>
> **Recommendation: route WBTC to its own `WBTC/USD` Chainlink feed** (§4.1) rather than to `BTC/USD`.
> Measured against Pragma's independent `WBTC/USD` key at the §11 fork block, the dedicated feed tracks
> it to **5.7 bps** where BTC parity is **10.1 bps** out — and more importantly, a dedicated feed keeps
> responding if WBTC depegs, which parity by construction cannot. It costs nothing: the feed is live,
> 8-decimal, and was 288s fresh at that block. Both options are quantified by
> `test_fork_wbtc_own_feed_beats_btc_parity_against_pragma`, so this is a decision with numbers behind
> it rather than a preference.
>
> The remaining seven wrappers have no such option, so everything below still applies to them
> unchanged: price-invariance across that set is the real exposure, and the controls are §9's
> monitoring and per-pair parameters, not a price haircut.
>
> Both compensating controls sit outside the oracle: the monitoring and automated pausing in §9,
> which is a precondition for step 4 of the migration (§10) and not a follow-up, and per-pair
> `max_ltv` / `liquidation_factor`, tightened for wrapper-vs-wrapper pairs. Do **not** express
> wrapper risk as a price haircut in the oracle — that is a worse-specified LTV, invisible in the
> pair config where risk is actually reviewed, and it distorts both sides of every pair the asset
> appears in.

## 5. Ekubo TWAP for EKUBO

EKUBO is the only asset in any V2 pool with a live Ekubo oracle-extension pool, quoted against ETH.
Core `0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b`,
oracle extension `0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f`.

The route is inherently a two-leg composition — the extension yields `EKUBO/ETH`, and USD requires
`ETH/USD` from Chainlink. Per §3.3 the quote leg is mandatory: `quote_asset = ETH`, resolved through
`price_terminal()`, and an invalid or missing ETH price makes the EKUBO price invalid. The TWAP is
never returned on its own.

### Suggested parameters

| Parameter                  | Value                                     | Rationale                                                                                                                                                                                                                                                                       |
| -------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TWAP window                | **3600s (1h)**                            | Pool-side liquidity is ~$61k — the thinnest of any asset routed to a live source. The window is the entire security budget: it converts a one-block displacement into an hour of repeatedly paid-for displacement. How much that actually costs is computed below, not assumed. |
| Minimum window enforced    | 1800s                                     | Hard floor in the router; reject any config below it.                                                                                                                                                                                                                           |
| Quote asset                | ETH                                       | Only oracle pool that exists. Avoids routing through a thin stable pair.                                                                                                                                                                                                        |
| Deviation vs spot          | 10%, **advisory**                         | Reported by `spot_deviation(asset)` for monitoring. It does **not** invalidate the price — see below.                                                                                                                                                                           |
| Debt cap for EKUBO markets | ≤10% of the computed 1h manipulation cost | The cap, not the oracle, is the control. It must be derived from the number below and re-derived whenever pool depth moves materially (§9).                                                                                                                                     |

The router reads the extension's cumulative-tick snapshots at `now` and `now - window` and derives
the geometric mean. It MUST return `is_valid: false` if the extension has no observation older than
the window (insufficient history), rather than silently shortening the window.

**Interface note.** The deployed extension's history accessor is
`get_earliest_observation_time(token_a, token_b) -> Option<u64>` — an _unordered_ pair, and an
`Option`, answering `None` when it tracks no observations for that pair. The `Option` is load-bearing
on the wire: `Some(t)` serialises as `[0, t]`, so reading the response as a bare `u64` yields the
variant tag `0` instead of the timestamp, which the "insufficient history" guard then turns into a
permanent `is_valid: false` for every `EkuboTwap` route. A mock answering `u64` cannot expose that, so
it is pinned by `test_fork_ekubo_extension_reports_real_observation_history` against the live
extension, and the mock in `mock_oracle_v2.cairo` answers the same `Option<u64>` shape.
`get_price_x128_over_last(base_token, quote_token, period) -> u256` needs no such care.

### Manipulation cost

Two different costs are involved here, and an earlier draft conflated them:

- **Instantaneous displacement.** One swap moves spot by `d`. The attacker unwinds in the same block,
  or arbitrageurs do it for them in the next one. The cost is the round trip — fees plus unrecovered
  slippage — a fraction of the notional moved, and on $61k of depth that is a small number for
  `d = 10%`. No capital is exposed over time.
- **Sustained displacement.** Moving a 1h geometric-mean TWAP by a meaningful fraction means holding
  spot displaced across most of the window. Arbitrageurs restore the pool continuously at the
  attacker's expense, so the attacker pays roughly the round-trip cost _again_ on each restoration:
  `cost ≈ round_trip_cost(d) × restorations_over_the_window`, on the order of 100+ restorations for
  one hour at Starknet's block cadence.

The two statements are consistent: one swap is cheap, an hour of swaps is not, and that ratio is
precisely what the window buys. But the ratio is finite and this pool is small — the product above,
on $61k of depth, is plausibly in the low tens of thousands of dollars, not millions. Two
consequences:

- The EKUBO debt cap must be **derived from that number**, using the pool's real fee tier and
  liquidity distribution rather than a notional constant. The calculation is a precondition for
  listing, not a judgement call made at listing time.
- If the honest number does not support a cap worth listing, the correct outcome is not to list
  EKUBO as collateral. The route stays specified and available for when depth justifies it, and for
  any asset that later gets an oracle-extension pool.

**Why spot deviation is advisory.** It is exactly the cheapness of _instantaneous_ displacement that
rules out an invalidating spot-vs-TWAP check. Because an invalid price blocks liquidations (§6.0),
such a rule hands an attacker a cheap, on-demand way to freeze every EKUBO market — including the
liquidation of their own underwater position. It converts a manipulation detector into a
manipulation tool. The TWAP window plus the debt cap is the security budget; deviation is a
monitoring signal that resolves to an operator pause (§9), not to an oracle state. The same
reasoning applies to a Pragma `EKUBO/USD` cross-check: useful as a monitored view, not as an
invalidation rule.

**Standing recommendation:** the same mechanism is available for any asset once an oracle-extension
pool is created for it. No other V2 asset has one today — including deep names like strkBTC ($5.7M),
USDC ($3.8M) and ETH ($2.4M). Creating oracle pools for those is cheap and would give the router a
genuine second source for cross-checking. Tracked as follow-up, not part of this spec.

## 6. Validation

Every route returns `AssetPrice { value, is_valid }`. Validity is the AND of all applicable checks.
No check reverts, no check writes storage, and no check emits an event.

### 6.0 The liveness budget

`pool.cairo::assert_security_invariants` rejects any position update where either price is invalid,
and it runs on liquidations as well — only `assert_position_invariants` is skipped there. An invalid
price therefore freezes borrow, repay, withdraw **and liquidation** on every pair that lists the
asset. Two consequences govern the rest of this section:

1. A validation rule that an outsider can trigger cheaply is an attack, not a protection.
2. A validation rule that fires on ordinary noise is an outage.

Invalidate when the price is unknown. Everything else is a cap, a pair parameter, or a pause.

**Confirmed against the deployed `Prime` pool.** Every failure shape freezes the pair — a terminal feed, a
composite route's ratio leg, a composite route's quote leg, and a `Scaled` route's quote leg — and
liquidation is blocked along with everything else, which is the point this section turns on. A composite
route makes the blast radius non-obvious: a stale **ETH/USD** feed freezes the wstETH/USDT pair, which
never mentions ETH. The pool's _views_ keep answering throughout (§3.4), so the failure stays diagnosable
from outside even while the market is frozen.

> **⚠️ The error a frozen update reports is not always the oracle one, and is sometimes actively
> misleading.** `update_position` runs `assert_position_invariants` _before_ > `assert_security_invariants`, and the former reads the price **value**, which the router still surfaces
> for a stale source — only the flag goes false (§6.1). The two cases diverge:
>
> | How the source failed                           | Price value           | Update rejected by       |
> | ----------------------------------------------- | --------------------- | ------------------------ |
> | Stale (heartbeat missed, feed halted)           | last answer, non-zero | `invalid-oracle`         |
> | Dead (panicked, entrypoint gone, answered zero) | `0`                   | **`not-collateralized`** |
>
> In the second case a perfectly healthy position is rejected as undercollateralized — the same message a
> genuinely unhealthy one produces. During an incident that is the wrong signal: it points an operator at
> the borrower rather than at the feed, and it is indistinguishable from the condition liquidators look
> for. Worth fixing by moving `assert_security_invariants` ahead of `assert_position_invariants` in
> `update_position`, which costs nothing and makes the oracle the named cause whenever it is the actual
> cause. Both messages are pinned by the fork tests (§11) so a change in either is visible.
>
> **It is not exploitable, and that is verified rather than assumed.** A healthy position that reads as
> undercollateralized cannot be liquidated: the same zero collateral price that produces the misleading
> message also makes `compute_liquidation_amounts` divide by it, so `liquidate_position` reverts with
> `mul_div division by zero` before it can act. Three fork tests against `Prime` establish this on a real
> 45.5% LTV position against an 80% limit — the liquidation attempt reverts while the source is dead; the
> _same_ attempt against healthy legs is refused with the honest `not-undercollateralized`, so the first
> revert is a genuinely different failure and not just "liquidation is hard to call"; and once the source
> answers again the position's LTV is exactly what it was and it is updatable again, so the window cost
> it nothing.
>
> Note what is doing the protecting: an incidental division by zero, not a check. If that arithmetic is
> ever reordered, made saturating, or given an early return for a zero price, the protection disappears
> while the misleading message remains.
>
> **The fix therefore has two parts**, and the first alone is not sufficient:
>
> 1. Move `assert_security_invariants` ahead of `assert_position_invariants` in `update_position`. This
>    makes the oracle the named cause on the write path whenever it is the actual cause.
> 2. Add an explicit price-validity check before `compute_liquidation_amounts` in `liquidate_position`.
>    Step 1 does not reach this path — the division happens before `update_position` is called — so
>    without it, liquidation keeps failing on arithmetic rather than on a stated reason.
>
> Both are in `pool.cairo`, not in the router. The fork tests note at each expectation whether step 1
> would change it, so that applying the fix produces two expected failures rather than a puzzle.

### 6.1 Non-zero

`value != 0` after scaling. A zero price must never be reported valid — it makes every position
appear infinitely collateralised or worthless depending on which side it lands on.

### 6.2 Freshness

`block_timestamp - updated_at <= max_staleness`, with `max_staleness == 0` meaning "disabled".
Guard against a future-dated `updated_at` (clamp the delta to 0) exactly as `oracle.cairo` does today.

Recommended starting values, given Chainlink's 24h heartbeats:

| Asset class    | `max_staleness` | Rationale                                                                                                                                                       |
| -------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ETH, BTC, STRK | 3600s           | Deviation-driven; these update many times a day in practice. A 1h bound detects a genuinely stalled feed quickly.                                               |
| USDC, USDT     | 90000s (25h)    | Flat pegs do not trigger the deviation threshold, so these legitimately approach the 24h heartbeat. A tighter bound would produce constant false invalidations. |

These numbers are no longer assumptions. At the fork block pinned in §11 the observed `updated_at`
gaps were: BTC 622s, ETH 141s, STRK 38s, LINK 32s — and USDC 51,782s, USDT 51,983s, i.e. **14.4h**.
DAI sat at 14,497s (4.0h), between the two classes: it is flat-pegged but thinner, so it belongs on the
stablecoin bound rather than the 1h one despite updating more often than USDC or USDT.

**A third class: exchange-rate feeds.** `WSTETH/ETH` was **35,927s (10.0h)** stale at the same block. It
is not a peg and not deviation-driven — it tracks staking accrual, which moves slowly and by small
increments, so the deviation threshold rarely fires and the heartbeat does most of the work. A 1h bound
invalidates it outright; it belongs on the 90000s bound alongside the stablecoins, for a different
reason. Pinned by `test_fork_wsteth_feed_needs_the_slow_staleness_bound`. Any future exchange-rate feed
(`stETH/ETH`, an LST ratio) should be assumed to behave the same way until measured.
A 1h bound on either stablecoin feed invalidates it outright;
`test_fork_staleness_bounds_match_observed_feed_ages` asserts both halves of that against mainnet, so
the 25h figure is calibrated rather than chosen.

The 25h bound means a halted stablecoin feed can be priced for a day. That gap is closed by
monitoring, not by tightening the on-chain bound: §9 alerts on staleness far below the invalidation
threshold, so the response is a pause with human judgement rather than a protocol-wide freeze on
every heartbeat that runs long. The final numbers come out of the shadow run (§11.2), which records
the observed maximum `updated_at` gap per feed.

### 6.3 Conversion-rate bounds (Scaled routes)

The conversion rate is read from a third-party contract and must be bounded. The bound is expressed
against a stored **anchor**, evaluated arithmetically at read time, because `price()` cannot write:

```
elapsed = saturating_sub(now, ref_timestamp)
upper   = min(ref_rate + max_growth_per_second × elapsed, max_rate)
lower   = ref_rate × min_rate_ratio / SCALE
valid   = rate >= lower && rate <= upper
```

- `ref_rate >= SCALE` is asserted at configuration time; Endur wrappers start at or above parity.
- `max_rate >= ref_rate` is asserted **every time the anchor is written**, not only at configuration
  time. The anchor is re-taken when a route change is applied and when `reanchor` is called, and a
  rate that crossed `max_rate` in between would otherwise install `upper = max_rate < ref_rate` and
  invalidate the asset on every subsequent read — with `reanchor` unable to recover it, since it
  would re-read the same out-of-range rate. Failing loudly instead tells the operator to raise the
  ceiling through a route change.
- `max_growth_per_second` is calibrated from observed rate history (§11.5) with headroom. It bounds
  the blast radius of a `total_assets` inflation bug or donation attack, and rejects a discontinuous
  jump, without needing to remember the previous read. **Zero is rejected**: it is the struct's
  natural unset value and would pin the ceiling at `ref_rate`, so the first wei of yield accrual
  would invalidate the route permanently.

  **Recommended value: `1e10` [SCALE/second].** Measured across 90.0 days of real rate history (blocks
  10,630,064 → 14,500,000), the observed slopes were xSTRK 2.52e9 (6.86%/yr — staking yield, the
  fastest by a wide margin), xsBTC 7.11e8, xtBTC 6.91e8, xWBTC 6.90e8, xstrkBTC 6.80e8, and xLBTC
  8.91e7 (0.27%/yr). `1e10` leaves 4x headroom over xSTRK and ~14x over the BTC wrappers. A single
  value across all six is deliberate — per-wrapper tuning buys little when the cone's job is to reject
  discontinuities, not to track yield. Pinned by
  `test_fork_cone_slope_covers_observed_wrapper_growth`, which re-derives the slopes from chain data
  rather than trusting the numbers above.

- `min_rate_ratio` (suggested `0.99 × SCALE`) replaces an earlier strict `rate >= SCALE` rule. A
  hard parity floor would freeze every market for a wrapper on a one-wei rounding dip, which by §6.0
  is an outage; a 1% floor still invalidates a genuine loss event.
- `max_rate` is the absolute ceiling and the fallback if the anchor is never refreshed.

**Anchor maintenance.** The cone widens with time since the anchor, so a fresh anchor is a tighter
bound. `reanchor(asset)` sets `(ref_rate, ref_timestamp)` to the rate the wrapper currently reports.
It takes that rate from the wrapper rather than from an argument, so the manager can re-accept
reality but cannot invent a rate: moving the anchor requires moving the wrapper. Changing the
_bounds_ (`max_growth_per_second`, `min_rate_ratio`, `max_rate`) is a route change and is
timelocked (§7).

Two properties of `reanchor` are deliberate and pull in opposite directions:

- **It is manager-gated, not permissionless.** An earlier draft made it permissionless on the
  argument that a fresh anchor is only ever a tighter bound. That is true of the _ceiling_, which
  `max_rate` caps absolutely, and false of the _floor_. Each refresh restates the floor as
  `ref_rate x min_rate_ratio`, so `n` refreshes give `min_rate_ratio^n x original`: at the suggested
  0.99, a 5% decline that the cone rejects outright passes in five 1% steps. There is no `min_rate`
  mirroring `max_rate` to stop the walk. An attacker cannot move the wrapper's rate, so the ratchet
  only ever follows a real decline — but a gradual loss is precisely the case `min_rate_ratio` exists
  to catch, so the floor is only a real bound while re-anchoring is a reviewed action.
- **It does not require the observed rate to be inside the current cone.** Refusing an out-of-cone
  rate would leave a genuine loss event recoverable only through a timelocked route change, i.e. a
  full delay of frozen markets on exactly the pairs the loss already hurt. Re-accepting reality has
  to be immediate, which is what makes the manager gate above load-bearing.

The cost of the manager gate is the operational burden the permissionless version was meant to
remove: anchors do not refresh themselves, and a cone left to widen is a weaker bound. §9 lists
proximity to the cone as a monitored signal for exactly this reason.

### 6.4 Unconfigured and deactivated assets

A route of kind `None` returns `AssetPrice { value: 0, is_valid: false }` rather than reverting as
`oracle.cairo` does today. This follows from the non-reverting goal, and it is safe because listing
already gates on validity: `pool.cairo`'s asset-config path asserts `oracle.price(asset).is_valid`,
so an unconfigured asset still cannot be added to a pool.

`None` is also the _deactivated_ state (§7): a live route may be moved to `None` through the
timelock, which freezes every pair listing the asset. The typed config is left in its map, so the
two cases are indistinguishable to `price()` by design — deactivation is expressed as the absence of
a route, not as a separate flag.

### 6.5 Rounding

All scaling uses `u256_mul_div(..., Rounding::Floor)`, as `oracle.cairo` does today, at every leg of
a composition. The direction is uniform rather than side-aware: a single price serves both the
collateral and the debt side of a pair, so there is no rounding direction that is conservative for
both, and consistency is worth more than a wei of bias.

### 6.6 Cross-source deviation (future)

No second reliable price source exists on Starknet for most of these assets today, so this is
groundwork rather than a live control. Where two sources do exist, expose the comparison as a view
(`deviation(asset) -> u128`) for the monitoring stack. Note that the read path is a view: it cannot
emit a `PriceDeviation` event, and a rule that invalidates on deviation inherits the §6.0 problem.
Promotion of any deviation check to an invalidating rule requires a source whose manipulation cost is
high enough that triggering it is not an attack in itself.

## 7. Access control and change management

- **Owner** (OZ two-step, as today): upgrades only, through the existing EIC machinery. Adding a new
  source kind is an upgrade.
- **Manager** (two-step, as today): route configuration.
- **New listing is instant.** `add_*_asset(asset, config)` requires the asset's current route to be
  `None`. Listing a new asset cannot affect an existing market.
- **Changing a live route is timelocked.** `propose_*_route` / `apply_route_change` with a delay
  (suggested 24–48h). Repointing a live asset's `feed`, `wrapper`, `base_asset`, staleness or rate
  bounds is equivalent to repricing collateral in every pool that lists it; a single compromised
  manager key should not be able to do that in one block. The proposal emits the **full typed
  config**, not just the kind, so the parameters of a pending change are public for the whole delay
  rather than only at the instant it lands.
- **Deactivation is a route change to `None`.** `propose_none_route(asset)` runs through the same
  timelock, because freezing every pair that lists an asset has the same blast radius as repricing
  it. The typed config survives, so reactivation is a fresh listing on a route that is once again
  `None` — instant, like any first listing. Deactivation is a deliberate freeze, not a quarantine;
  the control against a compromised manager re-pointing an asset is the timelock on the _live_ route,
  which a deactivation cycle does not shorten (it costs the full delay and freezes the market in
  between).
- **Exception:** `reanchor` (§6.3) is manager-only and immediate, because it takes the rate from the
  wrapper rather than from an argument and so grants no free parameter.
- **The emergency path is the pool's `pausing_agent`, not the oracle.** Deactivating a route freezes
  a market and is itself timelocked; pausing is faster, per-pool, and reversible by humans.
- **Every state change emits its full context.** Config writes carry the typed config and whether
  they are staged or live; `SetAnchor` carries the previous and new rate; `CancelRouteChange` carries
  what was cancelled; `ContractUpgraded` carries the EIC class hash. §9's monitoring is only as good
  as what the events expose.
- **No arbitrary code in the price path.** Because there is no adapter address, the only contracts
  the router ever calls are the ones named in a typed config, through interfaces fixed at compile
  time. Governance can change which feed is read; it cannot change what runs.

## 8. TBD assets

These have no acceptable route today and must not be migrated off Pragma until one exists. They stay
on the legacy `Pragma` route kind, which is retained precisely for this purpose.

| Asset                        | Problem                                                     | Direction |
| ---------------------------- | ----------------------------------------------------------- | --------- |
| **sUSN, mRe7BTC, mRe7YIELD** | No Chainlink feed and no on-chain wrapper rate on Starknet. | TBD.      |

**wstETH is resolved and no longer a §8 asset.** The `WSTETH/ETH` feed this section was waiting on
exists (§4.1), so wstETH takes exactly the route described here all along: `Chainlink` with
`quote_asset = ETH`, composed over `ETH/USD` per §3.3. At the §11 fork block that composition landed
**22 bps** from Pragma's independent `WSTETH/USD` key. It is the only live composed Chainlink route, so
it is also what finally exercises §3.3's second leg against a real source rather than a mock — see
`test_fork_wsteth_composes_through_the_live_eth_leg` and
`test_fork_wsteth_is_invalid_when_its_eth_leg_is`.

Two consequences for migration: wstETH moves from step 7 of §10 into step 3's group of direct feed
migrations (it composes, but both legs are Chainlink), and it needs the slow staleness bound, not the
1h one — see §6.2.

The legacy `Pragma` kind reproduces `oracle.cairo`'s spot semantics — same `OracleConfig` struct, same
`timeout` / `number_of_sources` checks, same scaling — with three differences:

1. The reads are syscall-isolated per §3.4.
2. An unset config returns invalid instead of reverting.
3. **There is no TWAP.** `oracle.cairo` optionally routes through the summary-stats contract's
   `calculate_twap` when `start_time_offset` and `time_window` are both non-zero. That path is not
   implemented here: it is a second external contract and a second set of failure modes on the read
   path, for a smoothing window that the `EkuboTwap` kind now provides against a source whose
   manipulation cost the router can actually reason about (§5). The router therefore takes no
   summary-stats address at all.

Because ignoring those two fields would give an operator a config that reads as a TWAP and resolves to
spot, they are **rejected at configuration time** (`pragma-twap-not-supported`) rather than ignored.
Any asset currently carrying a TWAP config on the live oracle must therefore be migrated with both
fields zeroed, which means accepting the spot answer for it — see §10, step 1.

## 9. Depeg monitoring and automated pausing

Parity pricing (§4.4) is safe only while each wrapper holds parity, and the oracle cannot detect a
depeg by construction — it is not looking at the wrapper's own market. Detection is an out-of-band
responsibility, and the response has to be faster than the arbitrage that a mispriced collateral
asset invites.

For each parity-priced wrapper (WBTC, tBTC, LBTC, SolvBTC, strkBTC, uniBTC, YBTC.B, USDC.e), monitor
its market price against the feed it is routed to — Ekubo pools on Starknet, and the deeper L1/L2
venues where it also trades, since a depeg usually appears off-Starknet first — with 1% as a warning
and 3% sustained as an action threshold. Alongside that, watch the leading indicators: pause,
upgrade, ownership, blacklist and minter-role events on the token and its bridge, proof-of-reserve
attestations going stale or short, and unexplained supply discontinuities. For the Endur wrappers,
any decrease in `convert_to_assets`, any jump larger than accrual explains, and proximity to the
§6.3 cone — the last being a signal to call the manager-only `reanchor`, which since it is no longer
permissionless is an operational task rather than something the world does for you. Per
feed and pool: a Chainlink `updated_at` gap crossing a warning level set well below the §6.2
invalidation bound (this is what makes the 25h stablecoin bound acceptable), Chainlink diverging
from Pragma's equivalent key, EKUBO spot against TWAP read from the router's `spot_deviation` view,
and Ekubo pool depth falling below the level the debt caps assumed.

The response needs no new protocol mechanism: the pool already exposes `pausing_agent()` and
`is_paused()`. Assign `pausing_agent` on each affected pool to a Hypernative-controlled, pause-only
account holding no other authority, and map the action-level triggers above — sustained >3%
deviation, a decreasing `convert_to_assets`, a paused bridge or changed minter role, a reserve
shortfall, a stale-and-diverging feed, EKUBO spot beyond its advisory bound — to an automatic pause
of exactly those pools listing the asset, since a depeg of one wrapper must not pause pools that do
not list it. Unpause is always manual: recovery requires a human judgement on whether the peg is
restored or the asset should be delisted. Finally, the monitor's own liveness must itself be
alerted on — a monitoring system that silently stops is worse than none, because the parity
assumption in §4.4 is justified by its existence.

## 10. Migration plan

1. **Deploy the router** with every asset configured to the legacy `Pragma` kind, carrying the
   `OracleConfig` values read from the live oracle. There are no adapters to deploy. Behaviour is
   identical to today for every asset on a spot config; for any asset whose live config sets
   `start_time_offset` and `time_window`, the router rejects the config outright (§8), so migrating it
   is a deliberate switch from the Pragma TWAP to Pragma spot and must be signed off as such. That
   audit is automated as `test_fork_no_live_asset_uses_the_removed_pragma_twap` (§11, item 14), which
   at the pinned block finds **no** listed asset on a TWAP config — so step 1 is behaviour-preserving
   as written. Re-run it against a current block before deploying, since it is the one place where
   that could change.
2. **Shadow mode.** Run the router alongside the live oracle. For each asset, record `price_new` vs
   `price_old` off-chain over a period covering at least one full stablecoin heartbeat cycle (>24h)
   and one volatile session. Deliverables: the `max_staleness` values in §6.2 and the
   `max_growth_per_second` / `max_rate` values in §6.3, both derived from observation rather than
   assumption.
3. **Migrate low-risk assets first** — ETH, USDC, USDC.e, USDT, STRK — by switching their routes to
   `Chainlink`. Direct feeds, no composition.
4. **Migrate BTC wrappers** only once §9 monitoring is live and the `pausing_agent` role is assigned,
   and once the pair-level parameters in §4.4 have been reviewed for wrapper-vs-wrapper pairs. Both
   are preconditions, not follow-ups.
5. **Migrate Endur wrappers** after the anchor and cone parameters from step 2 are set, with anchors
   taken immediately before the switch.
6. **Migrate EKUBO** last, with debt caps sized per §5.
7. **Leave TBD assets on the `Pragma` kind** until §8 resolves.
8. **Point the pool at the router** by setting the pool's `oracle` to the router address. Because
   the router implements `IOracle` unchanged, this is a single configuration change per pool.

Steps 3–7 are route changes on a live router and therefore pass through the §7 timelock. Step 1
configures a router that no pool reads yet, so it is not.

Note for step 5: the anchors taken in step 1 are stale by the length of the timelock by the time a
`Scaled` route lands, which is why `apply_route_change` re-takes the anchor from the wrapper on
application (§6.3) rather than using the one recorded at proposal time.

## 11. Test plan

Two suites. `src/test/test_oracle_v2.cairo` covers the items below against mocks, which is where
failure injection and boundary arithmetic belong. `src/test/test_oracle_v2_fork.cairo` covers what a
mock structurally cannot: that the interfaces in `src/vendor/` match the **deployed** ABIs, and that
the parameters recommended here hold against real data rather than against fixtures chosen to satisfy
them. It runs against the `OracleMainnet` fork profile, pinned to block **14,500,000** — the `Mainnet`
profile's block predates the five Endur BTC wrappers, where only xSTRK resolves.

> Fork tests need `universal-sierra-compiler` **>= 2.10.0**: the Ekubo oracle extension's class is
> Sierra 1.9.3, and older compilers fail to read it with "No matching ContractClass ... for version
> 1.9.3". The mock suite is unaffected.

The fork suite has already paid for itself twice: it resolved §4.1's open question about `answer`, and
it caught `get_earliest_observation_time` being `Option<u64>` rather than `u64` (§5) — a mismatch that
made every `EkuboTwap` route permanently invalid on mainnet while the whole mock suite passed.

Items 1–9 below are covered by the mock suite; the fork coverage is listed after them.

1. **Chainlink leg.** Each feed in §4.1: scaling from `feed_decimals` to SCALE, staleness boundary
   at exactly `max_staleness`, future-dated `updated_at` clamped to 0, zero answer and zero
   `updated_at` both invalid. A feed reporting `decimals` above `MAX_DECIMALS` is rejected at
   configuration time (§3.5).
2. **Shadow parity.** For every asset on a spot config, `price_new` within a tight bound of
   `price_old`, over the window described in §10.2. Assets on a Pragma TWAP config are expected to
   _diverge_ and must be compared against Pragma spot instead, per §8.
3. **Scaled leg.** Each wrapper in §4.3 against its live rate, plus a synthetic wrapper with
   `share_decimals != underlying_decimals` — the case that a `10^share_decimals` divisor would get
   wrong and no live wrapper would catch.
4. **Composition safety.** A quote asset that is itself non-terminal (`Scaled`, `EkuboTwap`, or a
   Chainlink route with its own `quote_asset`) returns invalid and does not recurse, for all three
   composite kinds. A mutual pair of routes quoting each other terminates.
   **Per-leg validation**, as tabulated in §3.3: for each of the three composite kinds, a failing ratio
   leg and a failing quote leg must each invalidate the composition on their own, and the two legs'
   parameters must not bleed into one another — a composed Chainlink route's ratio feed must be judged
   against its own `max_staleness` and its quote feed against the quote asset's. Also: deactivating a
   quote asset invalidates every composite standing on it, and in no failure mode does the composed
   value come out equal to the bare ratio.
5. **Quote leg mandatory.** An `EkuboTwap` or `Scaled` route with a zero or unconfigured
   `quote_asset` is rejected at configuration time, and — if reached through a quote asset whose
   route was later cleared — returns invalid rather than the bare ratio. Assert the returned value
   is not the unquoted ratio, since that is the failure that would read as valid.
6. **Rate bounds.** Cone arithmetic at the boundaries; `reanchor` manager-gated, restricted to the
   wrapper-reported rate, and accepted _outside_ the cone as well as inside it; an anchor above
   `max_rate` rejected on both write paths (`apply_route_change` and `reanchor`); a zero
   `max_growth_per_second` rejected at configuration time; a `wrapper` that is not the routed asset
   rejected at configuration time.
7. **Failure isolation.** A source that panics, a contract that lacks the entrypoint, and a source
   returning a malformed span each produce `is_valid: false` and no revert. A Pragma response
   carrying `decimals` above `MAX_DECIMALS` likewise degrades to `is_valid: false` rather than
   overflowing `pow_10` on the read path (§3.5). Asserted at the pool
   boundary as well as directly: `pool.add_asset` fails with the pool's own `oracle-price-invalid`
   rather than the source's panic, and `pool.check_collateralization` still returns — which holds
   only because the router swallowed the failure. An address with no class is out of scope for this
   property (§3.4); configuration-time validation covers it instead.
8. **Ekubo leg.** TWAP against a known window; insufficient history returns invalid; a window below
   `MIN_TWAP_WINDOW` is rejected at configuration time; an `oracle_extension` that does not answer
   `get_earliest_observation_time` is rejected at configuration time (§3.4). Precision: a base token
   with more decimals than its quote must normalise without the truncation a two-step
   `x128 -> SCALE -> decimals` conversion introduces (§3.3).
9. **Access control.** Timelock enforced on changes to a set route; instant path only for `None`;
   deactivation via `propose_none_route` timelocked, prices `{ 0, false }` once applied, leaves the
   typed config in place, and cannot be applied twice. Staged configs are cleared on both apply and
   cancel, so raw storage cannot be misread as a live proposal.

### Fork coverage

The asset list is not taken from §4.2 by hand. It is the 24 assets the deployed oracle has ever
configured, read off its `SetOracleConfig` events — which is how the two §4.2 corrections above were
found in the first place.

10. **Deployed ABIs.** The `Round` struct field-for-field (§4.1), and the extension's `Option<u64>`
    history accessor (§5). These are the two places where a wrong assumption is invisible to a mock,
    because the mock is written from the same assumption.
11. **Every feed a route actually reads**: 8 decimals, non-zero answer, complete round, plausible
    timestamp. A feed that has quietly stopped answering is caught before a market notices. DAI/USD and
    LINK/USD are excluded on purpose — nothing routes to them (§4.1).
12. **Every direct Chainlink route** (§4.2): ETH, STRK, both USDC addresses and USDT price in band and
    the two USDC rows price identically, since they share a feed.
13. **Parity pricing, asserted rather than described** (§4.2, §4.4): all eight BTC wrappers price
    _exactly_ equal — the price-invariance §4.4 warns about, stated as a test. The set spans 8, 10 and
    18 decimal tokens, which also pins that a direct Chainlink route is decimals-independent.
14. **The §4.4 regression, quantified**: WBTC is the only BTC wrapper with its own Pragma key, and the
    basis it currently carries is the whole signal the switch gives up.
15. **Every Scaled route** (§4.3, §11.3): all six wrappers' `asset()`, derived decimals, rate inside
    the cone, anchor equal to the observed rate, and `price == rate x base` exactly. Plus `reanchor`
    against a live wrapper.
16. **Calibration.** The §6.2 staleness bounds against observed feed ages, and the §6.3
    `max_growth_per_second` against 90 days of real rate history — both re-derived from chain data, not
    asserted from the numbers written here.
17. **The Ekubo leg** (§5): TWAP composition against the live ETH feed, 30m and 1h windows agreeing,
    the insufficient-history boundary found exactly at the pair's real earliest observation, and spot
    deviation computable but never invalidating.
18. **Composition and failure isolation against live contracts** (§3.3, §3.4): live Scaled and
    EkuboTwap routes resolve but never terminally, a live Scaled asset is refused as a quote leg, and a
    real deployed contract that passes configuration but lacks `latest_round_data` degrades to
    `is_valid: false` rather than reverting.
19. **A live route change** (§7): repointing a feed through the timelock, with the old route intact
    until it lands.
20. **Shadow parity across every planned route** (§11.2, §6.6) against the deployed oracle — genuinely
    independent sources, so the tolerances are the output that matters. Observed at the pinned block:
    direct feeds 1–17 bps; BTC parity 36 bps (Chainlink `BTC/USD` vs Pragma `BTC/USD`); WBTC 10 bps;
    Endur wrappers single-digit to tens of bps; **EKUBO 47 bps**. The ordering is exactly what §5
    predicts — the thin-pool leg is an order of magnitude looser than the direct feeds — and §6.6
    cannot promote any deviation check to an invalidating rule without numbers like these.
21. **Migration safety** (§8, §10 step 1). All 24 live `OracleConfig`s have `start_time_offset == 0`
    and `time_window == 0`, so no listed asset uses the summary-stats TWAP removed in §8. Each is also
    replayed into the router verbatim, and the router's price must equal the deployed oracle's
    **exactly** — which is the actual claim step 1 makes. The §8 assets are asserted to stay on the
    legacy kind, so a later change that quietly gives one of them a Chainlink or Scaled route has to
    come past this test.
22. **A dress rehearsal for §10 step 8**: every planned route configured on one router at one block,
    all 24 resolving valid and non-zero, with each asset's route _kind_ asserted to be the one §4.2
    plans rather than whatever happened to be configured.

23. **The composed Chainlink route** (§3.3, §8), against `WSTETH/ETH` — the only ETH-quoted feed on
    Starknet, and the only one that is not 8-decimal. Covers that `feed_decimals` is derived rather than
    assumed, that the composition equals `ratio x ETH/USD` exactly, that the route is not itself
    terminal, that wstETH does not price at ETH parity, and that a stale ETH leg invalidates the whole
    composition rather than leaking the bare ratio. Plus its staleness class (§6.2) and its 22 bps
    agreement with Pragma.
24. **The WBTC routing decision** (§4.4): BTC parity and the dedicated `WBTC/USD` feed, each measured
    against Pragma's independent key, so the choice is made on numbers.
25. **Pair invariance** (§3.3), against real positions in the deployed `Prime` pool: wstETH/ETH (80.5%
    LTV), xSTRK/STRK (83.0%) and xWBTC/WBTC (70.8%) each hold their solvency _and_ their LTV to within a
    basis point across five to eight orders of magnitude of their shared quote leg, judged by the pool's
    own `check_collateralization` against `Prime`'s own `max_ltv`. Plus the exact flip point, derived
    from the pool's `L` and `M` and asserted one basis point either side. The only direction a live pool
    cannot provide is a fall in an ERC-4626 conversion rate, since it comes from the deployed wrapper
    rather than a feed; that runs against the real `Pool` with mocked sources in the mock suite.
26. **The liveness budget** (§6.0), against `Prime`: each of the four failure shapes — terminal feed,
    composite ratio leg, composite quote leg, `Scaled` quote leg — freezes the pair; a stale ETH feed
    freezes a pair that does not list ETH; liquidation is blocked along with position updates; the pool's
    views keep answering in every case; and both rejection messages are pinned, including the misleading
    `not-collateralized` one (§6.0). Plus the three tests establishing that the misleading rejection is
    not exploitable: a healthy position reading as undercollateralized still cannot be liquidated, the
    honest refusal is a distinguishable failure, and the freeze leaves the position's LTV untouched.

## 12. Open questions

- ~~Can Chainlink support a `wstETH/ETH` or `stETH/ETH` feed on Starknet?~~ **Answered: yes, and it is
  already deployed** at `0x07ba92ee505a967f56253a5a51d8249c0515577fa9d1dea7f24e233ae3395184` (§4.1).
  wstETH is routed and tested (§8). Note the feed is 18-decimal and ETH-quoted, unlike every other
  Starknet feed.
- What timelock delay is right for §7 — long enough to be a real control, short enough to respond to
  a feed deprecation without an upgrade?

## Appendix A — reference addresses

| Contract                                  | Address                                                              |
| ----------------------------------------- | -------------------------------------------------------------------- |
| Current V2 oracle                         | `0x00fe4bfb1b353ba51eb34dff963017f94af5a5cf8bdf3dfc191c504657f3c05`  |
| V2 pool factory                           | `0x03760f903a37948f97302736f89ce30290e45f441559325026842b7a6fb388c0` |
| V2 pool class hash                        | `0x317ce57b2de4a0c482f0eed58a635d100ac5b4801b38251607dcfa35a4128`    |
| `Prime` pool (used by the §11 fork tests) | `0x451fe483d5921a2919ddd81d0de6696669bccdacd859f72a4fba7656b97c3b5`  |
| `Prime` curator (may call `set_oracle`)   | `0x5028372e584acb5e14de6737c6b46dd9319508ba584ba8c651ef848bedd6a7d`  |

Ten V2 pools were live at the §11 fork block, all already reading the current V2 oracle: `Prime`,
`Re7 STRK`, `Re7 ETH`, `Re7 xBTC`, `Re7 USDC Core`, `Re7 USDC Prime`, `Re7 USDC Stable Core`,
`Re7 Labs Starknet Ecosystem`, `Clearstar USDC Reactor` and `Attk`. `Prime` is the most active and holds
real positions in every pair §3.3's invariance argument concerns, which is why the fork tests use it.
Enumerate pools by filtering `ModifyPosition` on its event selector and keeping emitters whose class
hash is the one above — and note that address filters in `starknet_getEvents` must be **unpadded**
(`0x3760f9…`, not `0x03760f9…`), or they silently match nothing.
| Pragma oracle | `0x02a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b` |
| Pragma summary stats | `0x049eefafae944d07744d07cc72a5bf14728a6fb463c3eae5bca13552f5d455fd` (read by `oracle.cairo` only; the router takes no summary-stats address) |
| Ekubo core | `0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b` |
| Ekubo oracle extension | `0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f` |
| EKUBO token | `0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87` |
| ETH | `0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7` |
| USDC | `0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8` |
| STRK | `0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d` |
