use starknet::{ClassHash, ContractAddress};
use vesu::data_model::AssetPrice;
use vesu::oracle::OracleConfig;

/// Hard floor for the Ekubo TWAP window. A shorter window is rejected at configuration time.
pub const MIN_TWAP_WINDOW: u64 = 1800; // [seconds]
/// Period used by the `spot_deviation` monitoring view as a proxy for the spot price.
pub const SPOT_TWAP_WINDOW: u64 = 60; // [seconds]
pub const TWO_POW_128: u256 = 340282366920938463463374607431768211456;
/// Upper bound on any decimals value the router exponentiates. Every `pow_10` argument on the price
/// path comes from a source-reported `decimals`, and `10^n` overflows `u256` for `n >= 78` — a panic
/// inside `price()`, which the non-reverting guarantee does not permit. Cached decimals are bounded
/// at configuration time; the decimals a Pragma response carries are bounded at read time. The bound
/// also keeps `TWO_POW_128 * 10^n` and `SCALE * 10^n` inside `u256` for the Ekubo normalisation.
pub const MAX_DECIMALS: u8 = 30;

#[derive(PartialEq, Copy, Drop, Serde, Default, starknet::Store)]
pub enum PriceRouteKind {
    /// unconfigured
    #[default]
    None,
    /// direct feed; composed with `quote_asset` if the feed is not USD denominated
    Chainlink,
    /// base leg × on-chain ERC-4626 conversion rate
    Scaled,
    /// geomean TWAP from the Ekubo oracle extension, always composed with `quote_asset`
    EkuboTwap,
    /// legacy path, retained for assets without an acceptable route; spot only, no TWAP
    Pragma,
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct ChainlinkConfig {
    /// aggregator proxy
    pub feed: ContractAddress,
    /// derived at configuration time from `decimals()`; any value passed in is ignored
    pub feed_decimals: u8,
    /// [seconds] 0 = disabled
    pub max_staleness: u64,
    /// 0 = the feed is USD quoted and this route is terminal; otherwise the asset the feed is
    /// denominated in, which must itself be routed to a terminal kind
    pub quote_asset: ContractAddress,
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct ScaledConfig {
    /// the underlying asset, supplying the quote leg; must be routed to a terminal kind
    pub base_asset: ContractAddress,
    /// ERC-4626 shaped share token
    pub wrapper: ContractAddress,
    /// derived at configuration time; any value passed in is ignored
    pub share_decimals: u8,
    /// derived at configuration time; the divisor that normalises the rate to SCALE
    pub underlying_decimals: u8,
    /// [SCALE] anchor rate, derived at configuration time
    pub ref_rate: u128,
    /// [seconds] when the anchor was taken, derived at configuration time
    pub ref_timestamp: u64,
    /// [SCALE / second] slope of the upper bound
    pub max_growth_per_second: u128,
    /// [SCALE] lower bound as a fraction of `ref_rate`
    pub min_rate_ratio: u128,
    /// [SCALE] absolute ceiling
    pub max_rate: u128,
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct EkuboConfig {
    pub oracle_extension: ContractAddress,
    /// the pool's other token; MUST be non-zero — a pool ratio is never a USD price
    pub quote_asset: ContractAddress,
    /// derived at configuration time
    pub base_decimals: u8,
    /// derived at configuration time
    pub quote_decimals: u8,
    /// [seconds] >= MIN_TWAP_WINDOW
    pub window: u64,
    /// [SCALE] advisory bound, reported by `spot_deviation`, never invalidating
    pub max_spot_deviation: u128,
}

#[starknet::interface]
pub trait IOracleV2<TContractState> {
    fn route_kind(self: @TContractState, asset: ContractAddress) -> PriceRouteKind;
    fn chainlink_config(self: @TContractState, asset: ContractAddress) -> ChainlinkConfig;
    fn scaled_config(self: @TContractState, asset: ContractAddress) -> ScaledConfig;
    fn ekubo_config(self: @TContractState, asset: ContractAddress) -> EkuboConfig;
    fn pragma_config(self: @TContractState, asset: ContractAddress) -> OracleConfig;
    fn pragma_oracle(self: @TContractState) -> ContractAddress;
    fn route_timelock(self: @TContractState) -> u64;
    /// `(is_pending, kind, eta)` — `kind` is only meaningful while `is_pending` is true, since
    /// `None` is itself a proposable kind
    fn pending_route_change(self: @TContractState, asset: ContractAddress) -> (bool, PriceRouteKind, u64);

    /// price of `asset` resolved without composition; the quote leg of every composite route
    fn price_terminal(self: @TContractState, asset: ContractAddress) -> AssetPrice;
    /// [SCALE] conversion rate of a `Scaled` route and whether it is within its bounds
    fn conversion_rate(self: @TContractState, asset: ContractAddress) -> (u256, bool);
    /// [SCALE] geomean price of an `EkuboTwap` asset in its quote token over `period`
    fn twap(self: @TContractState, asset: ContractAddress, period: u64) -> (u256, bool);
    /// [SCALE] deviation of the short window TWAP from the configured window; monitoring only
    fn spot_deviation(self: @TContractState, asset: ContractAddress) -> (u256, bool);

    fn add_chainlink_asset(ref self: TContractState, asset: ContractAddress, config: ChainlinkConfig);
    fn add_scaled_asset(ref self: TContractState, asset: ContractAddress, config: ScaledConfig);
    fn add_ekubo_asset(ref self: TContractState, asset: ContractAddress, config: EkuboConfig);
    fn add_pragma_asset(ref self: TContractState, asset: ContractAddress, config: OracleConfig);

    fn propose_chainlink_route(ref self: TContractState, asset: ContractAddress, config: ChainlinkConfig);
    fn propose_scaled_route(ref self: TContractState, asset: ContractAddress, config: ScaledConfig);
    fn propose_ekubo_route(ref self: TContractState, asset: ContractAddress, config: EkuboConfig);
    fn propose_pragma_route(ref self: TContractState, asset: ContractAddress, config: OracleConfig);
    /// deactivates `asset`: its price becomes `{ value: 0, is_valid: false }` once applied, while
    /// its typed config stays in place
    fn propose_none_route(ref self: TContractState, asset: ContractAddress);
    fn apply_route_change(ref self: TContractState, asset: ContractAddress);
    fn cancel_route_change(ref self: TContractState, asset: ContractAddress);

    /// manager only: re-anchors to the rate the wrapper currently reports, both to tighten a stale
    /// cone and to re-accept a rate that has left it after a loss event
    fn reanchor(ref self: TContractState, asset: ContractAddress);

    fn manager(self: @TContractState) -> ContractAddress;
    fn pending_manager(self: @TContractState) -> ContractAddress;
    fn nominate_manager(ref self: TContractState, pending_manager: ContractAddress);
    fn accept_manager_ownership(ref self: TContractState);

    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(
        ref self: TContractState,
        new_implementation: ClassHash,
        eic_implementation_data: Option<(ClassHash, Span<felt252>)>,
    );
}

#[starknet::contract]
pub mod OracleV2 {
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::{call_contract_syscall, replace_class_syscall};
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use vesu::data_model::AssetPrice;
    use vesu::math::pow_10;
    use vesu::oracle::{IOracle, OracleConfig, assert_oracle_config};
    use vesu::oracle_v2::{
        ChainlinkConfig, EkuboConfig, IOracleV2, IOracleV2Dispatcher, IOracleV2DispatcherTrait, MAX_DECIMALS,
        MIN_TWAP_WINDOW, PriceRouteKind, SPOT_TWAP_WINDOW, ScaledConfig, TWO_POW_128,
    };
    use vesu::pool::{IEICDispatcherTrait, IEICLibraryDispatcher};
    use vesu::units::SCALE;
    use vesu::vendor::chainlink::{IChainlinkAggregatorDispatcher, IChainlinkAggregatorDispatcherTrait, Round};
    use vesu::vendor::ekubo::{IEkuboOracleDispatcher, IEkuboOracleDispatcherTrait};
    use vesu::vendor::erc20::{IERC20MetadataDispatcher, IERC20MetadataDispatcherTrait};
    use vesu::vendor::erc4626::{IERC4626Dispatcher, IERC4626DispatcherTrait};
    use vesu::vendor::pragma::{DataType, PragmaPricesResponse};

    #[storage]
    struct Storage {
        // asset -> route kind; the dispatcher for every price read. `None` is both "never configured"
        // and "deactivated": the typed config of a deactivated asset stays in its map, so reactivating
        // it is a route change rather than a fresh listing.
        routes: Map<ContractAddress, PriceRouteKind>,
        chainlink_configs: Map<ContractAddress, ChainlinkConfig>,
        scaled_configs: Map<ContractAddress, ScaledConfig>,
        ekubo_configs: Map<ContractAddress, EkuboConfig>,
        pragma_configs: Map<ContractAddress, OracleConfig>,
        // pending (timelocked) route changes; asset -> (kind, eta). `pending_active` is the gate,
        // not `pending_kinds`, because `None` is itself a proposable kind (a delisting).
        pending_active: Map<ContractAddress, bool>,
        pending_kinds: Map<ContractAddress, PriceRouteKind>,
        pending_etas: Map<ContractAddress, u64>,
        pending_chainlink_configs: Map<ContractAddress, ChainlinkConfig>,
        pending_scaled_configs: Map<ContractAddress, ScaledConfig>,
        pending_ekubo_configs: Map<ContractAddress, EkuboConfig>,
        pending_pragma_configs: Map<ContractAddress, OracleConfig>,
        // delay applied to any change of an already configured route
        route_timelock: u64,
        // the address of the pragma oracle contract
        pragma_oracle: ContractAddress,
        // the address of the manager of the oracle
        manager: ContractAddress,
        // the address of the pending (nominated) manager
        pending_manager: ContractAddress,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetRoute {
        #[key]
        pub asset: ContractAddress,
        pub kind: PriceRouteKind,
    }

    /// Emitted whenever a typed config is written, staged (`pending: true`) or live
    /// (`pending: false`), so the full parameters of a change are visible for the whole timelock
    /// rather than only at the moment it lands.
    #[derive(Drop, starknet::Event)]
    pub struct SetChainlinkConfig {
        #[key]
        pub asset: ContractAddress,
        pub pending: bool,
        pub config: ChainlinkConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetScaledConfig {
        #[key]
        pub asset: ContractAddress,
        pub pending: bool,
        pub config: ScaledConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetEkuboConfig {
        #[key]
        pub asset: ContractAddress,
        pub pending: bool,
        pub config: EkuboConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetPragmaConfig {
        #[key]
        pub asset: ContractAddress,
        pub pending: bool,
        pub config: OracleConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProposeRouteChange {
        #[key]
        pub asset: ContractAddress,
        pub kind: PriceRouteKind,
        pub eta: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CancelRouteChange {
        #[key]
        pub asset: ContractAddress,
        pub kind: PriceRouteKind,
        pub eta: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetAnchor {
        #[key]
        pub asset: ContractAddress,
        pub previous_ref_rate: u128,
        pub ref_rate: u128,
        pub ref_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetManager {
        #[key]
        pub manager: ContractAddress,
        pub previous_manager: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NominateManager {
        #[key]
        pub pending_manager: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractUpgraded {
        #[key]
        pub new_implementation: ClassHash,
        pub eic_implementation: Option<ClassHash>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        SetRoute: SetRoute,
        SetChainlinkConfig: SetChainlinkConfig,
        SetScaledConfig: SetScaledConfig,
        SetEkuboConfig: SetEkuboConfig,
        SetPragmaConfig: SetPragmaConfig,
        ProposeRouteChange: ProposeRouteChange,
        CancelRouteChange: CancelRouteChange,
        SetAnchor: SetAnchor,
        ContractUpgraded: ContractUpgraded,
        SetManager: SetManager,
        NominateManager: NominateManager,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        manager: ContractAddress,
        pragma_oracle: ContractAddress,
        route_timelock: u64,
    ) {
        self.ownable.initializer(owner);
        assert!(manager.is_non_zero(), "invalid-zero-manager");
        self.manager.write(manager);
        self.pending_manager.write(Zero::zero());

        assert!(pragma_oracle.is_non_zero(), "invalid-zero-pragma-oracle");
        self.pragma_oracle.write(pragma_oracle);
        self.route_timelock.write(route_timelock);
    }

    fn invalid() -> AssetPrice {
        AssetPrice { value: 0, is_valid: false }
    }

    fn zero_chainlink_config() -> ChainlinkConfig {
        ChainlinkConfig { feed: Zero::zero(), feed_decimals: 0, max_staleness: 0, quote_asset: Zero::zero() }
    }

    fn zero_scaled_config() -> ScaledConfig {
        ScaledConfig {
            base_asset: Zero::zero(),
            wrapper: Zero::zero(),
            share_decimals: 0,
            underlying_decimals: 0,
            ref_rate: 0,
            ref_timestamp: 0,
            max_growth_per_second: 0,
            min_rate_ratio: 0,
            max_rate: 0,
        }
    }

    fn zero_ekubo_config() -> EkuboConfig {
        EkuboConfig {
            oracle_extension: Zero::zero(),
            quote_asset: Zero::zero(),
            base_decimals: 0,
            quote_decimals: 0,
            window: 0,
            max_spot_deviation: 0,
        }
    }

    fn zero_pragma_config() -> OracleConfig {
        OracleConfig {
            pragma_key: 0,
            timeout: 0,
            number_of_sources: 0,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: Default::default(),
        }
    }

    /// Performs a contract call that must not revert the caller. A panicking, missing or
    /// non-deserializable callee yields `None` instead of propagating the failure.
    fn safe_call(target: ContractAddress, selector: felt252, calldata: Span<felt252>) -> Option<Span<felt252>> {
        match call_contract_syscall(target, selector, calldata) {
            Result::Ok(response) => Option::Some(response),
            Result::Err(_) => Option::None,
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        /// Reads the Chainlink feed and scales the answer to SCALE.
        /// # Returns
        /// * `ratio` - [SCALE] the feed answer, denominated in the feed's quote asset
        /// * `is_valid` - false if the read failed, the answer is zero, the round never completed
        ///   or the answer is stale
        fn chainlink_ratio(self: @ContractState, config: ChainlinkConfig) -> (u256, bool) {
            let response = match safe_call(config.feed, selector!("latest_round_data"), array![].span()) {
                Option::Some(response) => response,
                Option::None => { return (0, false); },
            };
            let mut span = response;
            let round = match Serde::<Round>::deserialize(ref span) {
                Option::Some(round) => round,
                Option::None => { return (0, false); },
            };
            if round.answer == 0 || round.updated_at == 0 {
                return (0, false);
            }

            let ratio = u256_mul_div(round.answer.into(), SCALE, pow_10(config.feed_decimals.into()), Rounding::Floor);

            let block_timestamp = get_block_timestamp();
            let time_delta = if round.updated_at >= block_timestamp {
                0
            } else {
                block_timestamp - round.updated_at
            };
            let fresh = config.max_staleness == 0 || time_delta <= config.max_staleness;

            (ratio, fresh && ratio != 0)
        }

        /// Reads `convert_to_assets(10^share_decimals)` from the wrapper and normalises it to SCALE.
        /// The divisor is `10^underlying_decimals` because the returned amount is denominated in
        /// underlying units, not in share units.
        fn conversion_rate_of(self: @ContractState, config: ScaledConfig) -> (u256, bool) {
            let mut calldata = array![];
            let shares: u256 = pow_10(config.share_decimals.into());
            Serde::serialize(@shares, ref calldata);

            let response = match safe_call(config.wrapper, selector!("convert_to_assets"), calldata.span()) {
                Option::Some(response) => response,
                Option::None => { return (0, false); },
            };
            let mut span = response;
            let assets = match Serde::<u256>::deserialize(ref span) {
                Option::Some(assets) => assets,
                Option::None => { return (0, false); },
            };

            let rate = u256_mul_div(assets, SCALE, pow_10(config.underlying_decimals.into()), Rounding::Floor);
            (rate, self.rate_in_bounds(config, rate))
        }

        /// Bounds the conversion rate against the stored anchor. Evaluated arithmetically so that
        /// `price` remains a view: the anchor is only ever written by `reanchor`.
        fn rate_in_bounds(self: @ContractState, config: ScaledConfig, rate: u256) -> bool {
            if rate == 0 {
                return false;
            }
            let block_timestamp = get_block_timestamp();
            let elapsed: u256 = if block_timestamp > config.ref_timestamp {
                (block_timestamp - config.ref_timestamp).into()
            } else {
                0
            };

            let mut upper = config.ref_rate.into() + config.max_growth_per_second.into() * elapsed;
            let max_rate: u256 = config.max_rate.into();
            if upper > max_rate {
                upper = max_rate;
            }
            let lower = u256_mul_div(config.ref_rate.into(), config.min_rate_ratio.into(), SCALE, Rounding::Floor);

            rate >= lower && rate <= upper
        }

        /// Geometric mean price of `asset` in its quote token over `period`, normalised to SCALE.
        fn ekubo_ratio(self: @ContractState, asset: ContractAddress, config: EkuboConfig, period: u64) -> (u256, bool) {
            let mut history_calldata = array![];
            Serde::serialize(@asset, ref history_calldata);
            Serde::serialize(@config.quote_asset, ref history_calldata);
            let history_response =
                match safe_call(
                    config.oracle_extension, selector!("get_earliest_observation_time"), history_calldata.span(),
                ) {
                Option::Some(response) => response,
                Option::None => { return (0, false); },
            };
            let mut history_span = history_response;
            // the extension answers `Option<u64>`: `None` means it tracks no observations for this
            // pair at all. Reading the response as a bare `u64` would pick up the variant tag.
            let earliest = match Serde::<Option<u64>>::deserialize(ref history_span) {
                Option::Some(observation) => match observation {
                    Option::Some(earliest) => earliest,
                    Option::None => { return (0, false); },
                },
                Option::None => { return (0, false); },
            };

            // insufficient history: never shorten the window silently
            let block_timestamp = get_block_timestamp();
            if earliest == 0 || earliest + period > block_timestamp {
                return (0, false);
            }

            let mut calldata = array![];
            Serde::serialize(@asset, ref calldata);
            Serde::serialize(@config.quote_asset, ref calldata);
            Serde::serialize(@period, ref calldata);
            let response =
                match safe_call(config.oracle_extension, selector!("get_price_x128_over_last"), calldata.span()) {
                Option::Some(response) => response,
                Option::None => { return (0, false); },
            };
            let mut span = response;
            let price_x128 = match Serde::<u256>::deserialize(ref span) {
                Option::Some(price_x128) => price_x128,
                Option::None => { return (0, false); },
            };

            // Raw token ratio scaled by 2^128 -> SCALE and adjusted for the tokens' decimals in a
            // single full-width mul_div. Truncating to SCALE first and adjusting afterwards would
            // cap the relative precision at 1 / (price * 10^quote_decimals / 10^base_decimals),
            // which for an 18 decimal token quoted against a 6 decimal one loses a percent of the
            // price at the low end. `MAX_DECIMALS` keeps both products inside u256.
            let ratio = u256_mul_div(
                price_x128,
                SCALE * pow_10(config.base_decimals.into()),
                TWO_POW_128 * pow_10(config.quote_decimals.into()),
                Rounding::Floor,
            );

            (ratio, ratio != 0)
        }

        /// Legacy Pragma path: the aggregated spot answer, with isolated reads.
        ///
        /// There is no TWAP branch. `oracle.cairo` optionally routes through the summary-stats
        /// contract's `calculate_twap`, and that is deliberately not reproduced here: it is a second
        /// external contract and a second set of failure modes on the read path, for a smoothing
        /// window whose job the `EkuboTwap` kind now does with a source the router can reason about.
        /// `start_time_offset` and `time_window` are therefore rejected at configuration time rather
        /// than ignored, so a TWAP-shaped config cannot silently resolve to spot.
        fn price_pragma(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            let OracleConfig {
                pragma_key, timeout, number_of_sources, aggregation_mode, ..,
            } = self.pragma_configs.read(asset);
            if pragma_key.is_zero() {
                return invalid();
            }

            let mut calldata = array![];
            Serde::serialize(@DataType::SpotEntry(pragma_key), ref calldata);
            Serde::serialize(@aggregation_mode, ref calldata);
            let data_response = match safe_call(self.pragma_oracle.read(), selector!("get_data"), calldata.span()) {
                Option::Some(response) => response,
                Option::None => { return invalid(); },
            };
            let mut data_span = data_response;
            let response = match Serde::<PragmaPricesResponse>::deserialize(ref data_span) {
                Option::Some(response) => response,
                Option::None => { return invalid(); },
            };

            // `decimals` is supplied by the source at read time and feeds `pow_10` directly, so it
            // has to be bounded here: an out of range value would overflow and revert the read path
            // rather than degrade to an invalid price.
            if response.decimals > MAX_DECIMALS.into() {
                return invalid();
            }
            let price = u256_mul_div(response.price.into(), SCALE, pow_10(response.decimals.into()), Rounding::Floor);

            let block_timestamp = get_block_timestamp();
            let time_delta = if response.last_updated_timestamp >= block_timestamp {
                0
            } else {
                block_timestamp - response.last_updated_timestamp
            };
            let is_valid = (timeout == 0 || time_delta <= timeout)
                && (number_of_sources <= response.num_sources_aggregated)
                && (response.price.into() != 0);

            AssetPrice { value: price, is_valid }
        }

        /// Multiplies a ratio by the price of the asset it is denominated in. The quote leg is
        /// resolved terminally, which caps composition at exactly one level.
        fn compose(
            self: @ContractState, ratio: u256, ratio_is_valid: bool, quote_asset: ContractAddress,
        ) -> AssetPrice {
            let quote = self.resolve(quote_asset, true);
            let value = u256_mul_div(ratio, quote.value, SCALE, Rounding::Floor);
            AssetPrice { value, is_valid: ratio_is_valid && quote.is_valid && value != 0 }
        }

        /// Resolves the price of `asset`. With `terminal_only` every composite kind returns invalid,
        /// which is what makes a cycle structurally impossible: the quote leg of a composite route
        /// can never itself compose.
        fn resolve(self: @ContractState, asset: ContractAddress, terminal_only: bool) -> AssetPrice {
            match self.routes.read(asset) {
                PriceRouteKind::None => invalid(),
                PriceRouteKind::Pragma => self.price_pragma(asset),
                PriceRouteKind::Chainlink => {
                    let config = self.chainlink_configs.read(asset);
                    let (ratio, ratio_is_valid) = self.chainlink_ratio(config);
                    if config.quote_asset.is_zero() {
                        AssetPrice { value: ratio, is_valid: ratio_is_valid && ratio != 0 }
                    } else if terminal_only {
                        invalid()
                    } else {
                        self.compose(ratio, ratio_is_valid, config.quote_asset)
                    }
                },
                PriceRouteKind::Scaled => {
                    if terminal_only {
                        return invalid();
                    }
                    let config = self.scaled_configs.read(asset);
                    let (rate, rate_is_valid) = self.conversion_rate_of(config);
                    self.compose(rate, rate_is_valid, config.base_asset)
                },
                PriceRouteKind::EkuboTwap => {
                    if terminal_only {
                        return invalid();
                    }
                    let config = self.ekubo_configs.read(asset);
                    let (ratio, ratio_is_valid) = self.ekubo_ratio(asset, config, config.window);
                    self.compose(ratio, ratio_is_valid, config.quote_asset)
                },
            }
        }

        fn assert_manager(self: @ContractState) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
        }

        /// A quote leg must resolve without composing: a USD denominated Chainlink feed, or Pragma.
        fn assert_terminal_route(self: @ContractState, quote_asset: ContractAddress) {
            match self.routes.read(quote_asset) {
                PriceRouteKind::Pragma => {},
                PriceRouteKind::Chainlink => {
                    assert!(self.chainlink_configs.read(quote_asset).quote_asset.is_zero(), "quote-asset-not-terminal");
                },
                _ => { assert!(false, "quote-asset-not-terminal"); },
            }
        }

        /// Fills in the derived fields of a Chainlink config and validates the rest.
        fn validated_chainlink_config(
            self: @ContractState, asset: ContractAddress, config: ChainlinkConfig,
        ) -> ChainlinkConfig {
            assert!(config.feed.is_non_zero(), "invalid-zero-feed");
            if config.quote_asset.is_non_zero() {
                assert!(config.quote_asset != asset, "self-referential-quote-asset");
                self.assert_terminal_route(config.quote_asset);
            }
            let feed_decimals = IChainlinkAggregatorDispatcher { contract_address: config.feed }.decimals();
            assert!(feed_decimals <= MAX_DECIMALS, "feed-decimals-out-of-range");
            ChainlinkConfig { feed_decimals, ..config }
        }

        /// Fills in the derived fields of a Scaled config (decimals and anchor) and validates the rest.
        fn validated_scaled_config(self: @ContractState, asset: ContractAddress, config: ScaledConfig) -> ScaledConfig {
            assert!(config.wrapper.is_non_zero(), "invalid-zero-wrapper");
            // The rate is read from `wrapper` but the route is keyed on `asset`; letting them differ
            // is a degree of freedom with no use, and a config error that silently prices one token
            // off another token's rate.
            assert!(config.wrapper == asset, "wrapper-must-be-the-asset");
            assert!(config.base_asset.is_non_zero(), "invalid-zero-base-asset");
            assert!(config.base_asset != asset, "self-referential-base-asset");
            self.assert_terminal_route(config.base_asset);

            let wrapper = IERC4626Dispatcher { contract_address: config.wrapper };
            assert!(wrapper.asset() == config.base_asset, "wrapper-underlying-mismatch");
            let share_decimals = wrapper.decimals();
            let underlying_decimals = IERC20MetadataDispatcher { contract_address: config.base_asset }.decimals();
            assert!(share_decimals <= MAX_DECIMALS, "share-decimals-out-of-range");
            assert!(underlying_decimals <= MAX_DECIMALS, "underlying-decimals-out-of-range");

            assert!(
                config.min_rate_ratio != 0 && config.min_rate_ratio <= SCALE.try_into().unwrap(),
                "invalid-min-rate-ratio",
            );
            // Zero is the struct's natural unset value and would pin the ceiling at `ref_rate`, so
            // the first wei of yield accrual would invalidate the route permanently.
            assert!(config.max_growth_per_second != 0, "invalid-zero-max-growth");

            let shares: u256 = pow_10(share_decimals.into());
            let assets = wrapper.convert_to_assets(shares);
            let rate = u256_mul_div(assets, SCALE, pow_10(underlying_decimals.into()), Rounding::Floor);
            assert!(rate >= SCALE, "anchor-rate-below-parity");
            let ref_rate: u128 = rate.try_into().expect('anchor-rate-overflow');
            assert!(config.max_rate >= ref_rate, "max-rate-below-anchor");

            ScaledConfig {
                share_decimals, underlying_decimals, ref_rate, ref_timestamp: get_block_timestamp(), ..config,
            }
        }

        /// Fills in the derived fields of an Ekubo config and validates the rest.
        fn validated_ekubo_config(self: @ContractState, asset: ContractAddress, config: EkuboConfig) -> EkuboConfig {
            assert!(config.oracle_extension.is_non_zero(), "invalid-zero-oracle-extension");
            // a pool ratio is never a USD price: there is no terminal Ekubo route
            assert!(config.quote_asset.is_non_zero(), "invalid-zero-quote-asset");
            assert!(config.quote_asset != asset, "self-referential-quote-asset");
            self.assert_terminal_route(config.quote_asset);
            assert!(config.window >= MIN_TWAP_WINDOW, "twap-window-too-short");

            // Read the extension once here, with an ordinary dispatcher. A call to an address with
            // no class deployed is not recoverable at the syscall level, so `safe_call` on the read
            // path cannot degrade it to an invalid price — it would revert every `price()` call.
            // Probing at write time is what keeps such an address out of a route in the first place.
            let earliest = IEkuboOracleDispatcher { contract_address: config.oracle_extension }
                .get_earliest_observation_time(asset, config.quote_asset);
            // a pool with no observations yet is a valid state; the read path reports it invalid
            let _ = earliest;

            let base_decimals = IERC20MetadataDispatcher { contract_address: asset }.decimals();
            let quote_decimals = IERC20MetadataDispatcher { contract_address: config.quote_asset }.decimals();
            assert!(base_decimals <= MAX_DECIMALS, "base-decimals-out-of-range");
            assert!(quote_decimals <= MAX_DECIMALS, "quote-decimals-out-of-range");

            EkuboConfig { base_decimals, quote_decimals, ..config }
        }

        fn set_route(ref self: ContractState, asset: ContractAddress, kind: PriceRouteKind) {
            self.routes.write(asset, kind);
            self.emit(SetRoute { asset, kind });
        }

        /// `assert_oracle_config` plus the rejection of the summary-stats TWAP parameters, which this
        /// router does not implement. Ignoring them would give an operator a config that reads as a
        /// TWAP and resolves to spot.
        fn validated_pragma_config(self: @ContractState, config: OracleConfig) -> OracleConfig {
            assert_oracle_config(config);
            assert!(config.start_time_offset == 0 && config.time_window == 0, "pragma-twap-not-supported");
            config
        }

        fn assert_unrouted(self: @ContractState, asset: ContractAddress) {
            assert!(asset.is_non_zero(), "invalid-zero-asset");
            assert!(self.routes.read(asset) == PriceRouteKind::None, "route-already-set");
        }

        /// Registers a pending route change. Any change to an asset with a live route passes through
        /// the timelock; listing a new asset does not.
        fn propose(ref self: ContractState, asset: ContractAddress, kind: PriceRouteKind) {
            assert!(self.routes.read(asset) != PriceRouteKind::None, "route-not-set");
            let eta = get_block_timestamp() + self.route_timelock.read();
            self.pending_active.write(asset, true);
            self.pending_kinds.write(asset, kind);
            self.pending_etas.write(asset, eta);
            self.emit(ProposeRouteChange { asset, kind, eta });
        }

        /// Discards a staged change. `pending_active` alone would be enough to make the staged
        /// config unreachable; it is zeroed too so that a reader of raw storage cannot mistake a
        /// stale entry for a live proposal.
        fn clear_pending(ref self: ContractState, asset: ContractAddress, kind: PriceRouteKind) {
            self.pending_active.write(asset, false);
            self.pending_kinds.write(asset, PriceRouteKind::None);
            self.pending_etas.write(asset, 0);
            match kind {
                PriceRouteKind::None => {},
                PriceRouteKind::Chainlink => self.pending_chainlink_configs.write(asset, zero_chainlink_config()),
                PriceRouteKind::Scaled => self.pending_scaled_configs.write(asset, zero_scaled_config()),
                PriceRouteKind::EkuboTwap => self.pending_ekubo_configs.write(asset, zero_ekubo_config()),
                PriceRouteKind::Pragma => self.pending_pragma_configs.write(asset, zero_pragma_config()),
            }
        }

        /// Re-anchors a `Scaled` route to the rate the wrapper currently reports and emits the
        /// change. Rejects an anchor its own ceiling would already exclude: that would leave
        /// `upper = max_rate < ref_rate`, invalidating the asset on every subsequent read.
        fn write_anchor(ref self: ContractState, asset: ContractAddress, config: ScaledConfig) -> ScaledConfig {
            let previous_ref_rate = self.scaled_configs.read(asset).ref_rate;
            let ref_rate = self.observed_rate(config);
            assert!(config.max_rate >= ref_rate, "max-rate-below-anchor");
            let ref_timestamp = get_block_timestamp();
            let anchored = ScaledConfig { ref_rate, ref_timestamp, ..config };
            self.scaled_configs.write(asset, anchored);
            self.emit(SetAnchor { asset, previous_ref_rate, ref_rate, ref_timestamp });
            anchored
        }

        /// Reads the current rate of a `Scaled` route directly from the wrapper.
        fn observed_rate(self: @ContractState, config: ScaledConfig) -> u128 {
            let wrapper = IERC4626Dispatcher { contract_address: config.wrapper };
            let shares: u256 = pow_10(config.share_decimals.into());
            let rate = u256_mul_div(
                wrapper.convert_to_assets(shares), SCALE, pow_10(config.underlying_decimals.into()), Rounding::Floor,
            );
            rate.try_into().expect('anchor-rate-overflow')
        }
    }

    #[abi(embed_v0)]
    impl OracleImpl of IOracle<ContractState> {
        /// Returns the current price for an asset and the validity status of the price.
        /// Never reverts: a failed, stale or out of bounds source is reported as invalid.
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `AssetPrice` - latest price of the asset and its validity
        fn price(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            self.resolve(asset, false)
        }
    }

    #[abi(embed_v0)]
    impl OracleV2Impl of IOracleV2<ContractState> {
        fn route_kind(self: @ContractState, asset: ContractAddress) -> PriceRouteKind {
            self.routes.read(asset)
        }

        fn chainlink_config(self: @ContractState, asset: ContractAddress) -> ChainlinkConfig {
            self.chainlink_configs.read(asset)
        }

        fn scaled_config(self: @ContractState, asset: ContractAddress) -> ScaledConfig {
            self.scaled_configs.read(asset)
        }

        fn ekubo_config(self: @ContractState, asset: ContractAddress) -> EkuboConfig {
            self.ekubo_configs.read(asset)
        }

        fn pragma_config(self: @ContractState, asset: ContractAddress) -> OracleConfig {
            self.pragma_configs.read(asset)
        }

        fn pragma_oracle(self: @ContractState) -> ContractAddress {
            self.pragma_oracle.read()
        }

        fn route_timelock(self: @ContractState) -> u64 {
            self.route_timelock.read()
        }

        fn pending_route_change(self: @ContractState, asset: ContractAddress) -> (bool, PriceRouteKind, u64) {
            (self.pending_active.read(asset), self.pending_kinds.read(asset), self.pending_etas.read(asset))
        }

        fn price_terminal(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            self.resolve(asset, true)
        }

        fn conversion_rate(self: @ContractState, asset: ContractAddress) -> (u256, bool) {
            if self.routes.read(asset) != PriceRouteKind::Scaled {
                return (0, false);
            }
            self.conversion_rate_of(self.scaled_configs.read(asset))
        }

        fn twap(self: @ContractState, asset: ContractAddress, period: u64) -> (u256, bool) {
            if self.routes.read(asset) != PriceRouteKind::EkuboTwap {
                return (0, false);
            }
            self.ekubo_ratio(asset, self.ekubo_configs.read(asset), period)
        }

        fn spot_deviation(self: @ContractState, asset: ContractAddress) -> (u256, bool) {
            if self.routes.read(asset) != PriceRouteKind::EkuboTwap {
                return (0, false);
            }
            let config = self.ekubo_configs.read(asset);
            let (window_ratio, window_is_valid) = self.ekubo_ratio(asset, config, config.window);
            let (spot_ratio, spot_is_valid) = self.ekubo_ratio(asset, config, SPOT_TWAP_WINDOW);
            if !window_is_valid || !spot_is_valid || window_ratio == 0 {
                return (0, false);
            }
            let delta = if spot_ratio > window_ratio {
                spot_ratio - window_ratio
            } else {
                window_ratio - spot_ratio
            };
            (u256_mul_div(delta, SCALE, window_ratio, Rounding::Floor), true)
        }

        /// Lists a new asset. Only valid while the asset has no route, so listing can never
        /// affect an existing market; every later change goes through `propose_*` / `apply`.
        fn add_chainlink_asset(ref self: ContractState, asset: ContractAddress, config: ChainlinkConfig) {
            self.assert_manager();
            self.assert_unrouted(asset);
            let config = self.validated_chainlink_config(asset, config);
            self.chainlink_configs.write(asset, config);
            self.emit(SetChainlinkConfig { asset, pending: false, config });
            self.set_route(asset, PriceRouteKind::Chainlink);
        }

        fn add_scaled_asset(ref self: ContractState, asset: ContractAddress, config: ScaledConfig) {
            self.assert_manager();
            self.assert_unrouted(asset);
            let config = self.validated_scaled_config(asset, config);
            self.scaled_configs.write(asset, config);
            self.emit(SetScaledConfig { asset, pending: false, config });
            self
                .emit(
                    SetAnchor {
                        asset, previous_ref_rate: 0, ref_rate: config.ref_rate, ref_timestamp: config.ref_timestamp,
                    },
                );
            self.set_route(asset, PriceRouteKind::Scaled);
        }

        fn add_ekubo_asset(ref self: ContractState, asset: ContractAddress, config: EkuboConfig) {
            self.assert_manager();
            self.assert_unrouted(asset);
            let config = self.validated_ekubo_config(asset, config);
            self.ekubo_configs.write(asset, config);
            self.emit(SetEkuboConfig { asset, pending: false, config });
            self.set_route(asset, PriceRouteKind::EkuboTwap);
        }

        fn add_pragma_asset(ref self: ContractState, asset: ContractAddress, config: OracleConfig) {
            self.assert_manager();
            self.assert_unrouted(asset);
            let config = self.validated_pragma_config(config);
            self.pragma_configs.write(asset, config);
            self.emit(SetPragmaConfig { asset, pending: false, config });
            self.set_route(asset, PriceRouteKind::Pragma);
        }

        fn propose_chainlink_route(ref self: ContractState, asset: ContractAddress, config: ChainlinkConfig) {
            self.assert_manager();
            let config = self.validated_chainlink_config(asset, config);
            self.pending_chainlink_configs.write(asset, config);
            self.propose(asset, PriceRouteKind::Chainlink);
            self.emit(SetChainlinkConfig { asset, pending: true, config });
        }

        fn propose_scaled_route(ref self: ContractState, asset: ContractAddress, config: ScaledConfig) {
            self.assert_manager();
            let config = self.validated_scaled_config(asset, config);
            self.pending_scaled_configs.write(asset, config);
            self.propose(asset, PriceRouteKind::Scaled);
            self.emit(SetScaledConfig { asset, pending: true, config });
        }

        fn propose_ekubo_route(ref self: ContractState, asset: ContractAddress, config: EkuboConfig) {
            self.assert_manager();
            let config = self.validated_ekubo_config(asset, config);
            self.pending_ekubo_configs.write(asset, config);
            self.propose(asset, PriceRouteKind::EkuboTwap);
            self.emit(SetEkuboConfig { asset, pending: true, config });
        }

        fn propose_pragma_route(ref self: ContractState, asset: ContractAddress, config: OracleConfig) {
            self.assert_manager();
            let config = self.validated_pragma_config(config);
            self.pending_pragma_configs.write(asset, config);
            self.propose(asset, PriceRouteKind::Pragma);
            self.emit(SetPragmaConfig { asset, pending: true, config });
        }

        /// Deactivates `asset`. Its route becomes `None`, which prices it
        /// `{ value: 0, is_valid: false }` and so freezes every pair listing it — the same blast
        /// radius as any other route change, hence the same timelock. The typed config is left in
        /// place, so reactivating is a matter of proposing the kind again. The pool's `pausing_agent`
        /// remains the fast emergency path.
        fn propose_none_route(ref self: ContractState, asset: ContractAddress) {
            self.assert_manager();
            self.propose(asset, PriceRouteKind::None);
        }

        /// Applies a route change once its timelock has elapsed.
        fn apply_route_change(ref self: ContractState, asset: ContractAddress) {
            self.assert_manager();
            assert!(self.pending_active.read(asset), "no-pending-route-change");
            let kind = self.pending_kinds.read(asset);
            let eta = self.pending_etas.read(asset);
            assert!(get_block_timestamp() >= eta, "route-change-timelocked");

            match kind {
                // a delisting stages no config
                PriceRouteKind::None => {},
                PriceRouteKind::Chainlink => {
                    let config = self.pending_chainlink_configs.read(asset);
                    self.chainlink_configs.write(asset, config);
                    self.emit(SetChainlinkConfig { asset, pending: false, config });
                },
                PriceRouteKind::Scaled => {
                    // re-anchor on application: the anchor taken at proposal time is stale by the
                    // length of the timelock. `write_anchor` re-checks the anchor against the
                    // ceiling, which the staged config was only checked against at proposal time.
                    let config = self.write_anchor(asset, self.pending_scaled_configs.read(asset));
                    self.emit(SetScaledConfig { asset, pending: false, config });
                },
                PriceRouteKind::EkuboTwap => {
                    let config = self.pending_ekubo_configs.read(asset);
                    self.ekubo_configs.write(asset, config);
                    self.emit(SetEkuboConfig { asset, pending: false, config });
                },
                PriceRouteKind::Pragma => {
                    let config = self.pending_pragma_configs.read(asset);
                    self.pragma_configs.write(asset, config);
                    self.emit(SetPragmaConfig { asset, pending: false, config });
                },
            }

            self.clear_pending(asset, kind);
            self.set_route(asset, kind);
        }

        fn cancel_route_change(ref self: ContractState, asset: ContractAddress) {
            self.assert_manager();
            assert!(self.pending_active.read(asset), "no-pending-route-change");
            let kind = self.pending_kinds.read(asset);
            let eta = self.pending_etas.read(asset);
            self.clear_pending(asset, kind);
            self.emit(CancelRouteChange { asset, kind, eta });
        }

        /// Re-anchors to the rate the wrapper currently reports. It takes that rate from the wrapper
        /// rather than from an argument, so it grants no free parameter: moving the anchor requires
        /// moving the wrapper itself.
        ///
        /// Deliberately manager gated rather than permissionless. Each refresh restates the floor as
        /// `ref_rate * min_rate_ratio`, so repeated refreshes walk the floor down multiplicatively
        /// and a decline the cone rejects in one step passes in several. There is no `min_rate` to
        /// stop that the way `max_rate` caps the ceiling, so the floor is only a real bound while
        /// re-anchoring is a reviewed action.
        ///
        /// Equally deliberately, it does *not* require the observed rate to be inside the current
        /// cone. Refusing an out of cone rate would leave a genuine loss event recoverable only by a
        /// timelocked route change, i.e. a full delay of frozen markets on exactly the pairs the
        /// loss already hurt.
        fn reanchor(ref self: ContractState, asset: ContractAddress) {
            self.assert_manager();
            assert!(self.routes.read(asset) == PriceRouteKind::Scaled, "not-a-scaled-route");
            self.write_anchor(asset, self.scaled_configs.read(asset));
        }

        fn manager(self: @ContractState) -> ContractAddress {
            self.manager.read()
        }

        fn pending_manager(self: @ContractState) -> ContractAddress {
            self.pending_manager.read()
        }

        fn nominate_manager(ref self: ContractState, pending_manager: ContractAddress) {
            self.assert_manager();
            self.pending_manager.write(pending_manager);
            self.emit(NominateManager { pending_manager });
        }

        fn accept_manager_ownership(ref self: ContractState) {
            let new_manager = self.pending_manager.read();
            assert!(get_caller_address() == new_manager, "caller-not-new-manager");

            let previous_manager = self.manager.read();
            self.pending_manager.write(Zero::zero());
            self.manager.write(new_manager);
            self.emit(SetManager { manager: new_manager, previous_manager });
        }

        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu Oracle V2'
        }

        fn upgrade(
            ref self: ContractState,
            new_implementation: ClassHash,
            eic_implementation_data: Option<(ClassHash, Span<felt252>)>,
        ) {
            self.ownable.assert_only_owner();

            let mut eic_class_hash = Option::None;
            if let Some((eic_implementation, eic_data)) = eic_implementation_data {
                IEICLibraryDispatcher { class_hash: eic_implementation }.eic_initialize(eic_data);
                eic_class_hash = Option::Some(eic_implementation);
            }
            replace_class_syscall(new_implementation).unwrap_syscall();
            // Check to prevent mistakes when upgrading the contract
            let new_name = IOracleV2Dispatcher { contract_address: get_contract_address() }.upgrade_name();
            assert(new_name == self.upgrade_name(), 'invalid upgrade name');
            self.emit(ContractUpgraded { new_implementation, eic_implementation: eic_class_hash });
        }
    }
}
