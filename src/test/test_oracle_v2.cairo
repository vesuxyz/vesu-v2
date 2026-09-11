#[cfg(test)]
mod TestOracleV2 {
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use snforge_std::{
        CheatSpan, DeclareResultTrait, EventSpyAssertionsTrait, cheat_caller_address, declare, load, map_entry_address,
        spy_events, start_cheat_block_timestamp_global, store,
    };
    use starknet::{ContractAddress, contract_address_const, get_block_timestamp};
    use vesu::common::is_collateralized;
    use vesu::data_model::{Amount, AmountDenomination, AssetParams, ModifyPositionParams, PairConfig};
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::math::pow_10;
    use vesu::oracle::{
        IOracleDispatcher, IOracleDispatcherTrait, IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait, OracleConfig,
    };
    use vesu::oracle_v2::{
        ChainlinkConfig, EkuboConfig, IOracleV2Dispatcher, IOracleV2DispatcherTrait, MIN_TWAP_WINDOW, OracleV2,
        PriceRouteKind, SPOT_TWAP_WINDOW, ScaledConfig, TWO_POW_128,
    };
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    // the summary-stats contract is still a constructor argument of the *legacy* oracle, which the
    // shadow parity tests deploy; the router itself no longer reads it
    use vesu::test::mock_oracle::{
        IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait, IMockPragmaSummaryDispatcher,
    };
    use vesu::test::mock_oracle_v2::{
        IMockChainlinkFeedDispatcher, IMockChainlinkFeedDispatcherTrait, IMockERC4626Dispatcher,
        IMockERC4626DispatcherTrait, IMockEkuboOracleDispatcher, IMockEkuboOracleDispatcherTrait,
        IMockOracleV2UpgradeDispatcher, IMockOracleV2UpgradeDispatcherTrait, IMockWrapperTokenDispatcher,
        IMockWrapperTokenDispatcherTrait,
    };
    use vesu::test::setup_v2::{deploy_asset_with_decimals, deploy_contract, deploy_with_args};
    use vesu::units::{PERCENT, SCALE};
    use vesu::vendor::pragma::AggregationMode;

    const TIMELOCK: u64 = 86400; // 24h
    const START_TIME: u64 = 1_000_000;
    const PRAGMA_KEY: felt252 = 'ASSET/USD';

    /// The Ekubo legs are computed from a 2^128 scaled pool ratio, so a floor rounding of a few
    /// wei is expected; the fixtures use binary fractions where an exact assertion is possible.
    fn assert_approx(actual: u256, expected: u256, tolerance: u256, message: ByteArray) {
        let delta = if actual > expected {
            actual - expected
        } else {
            expected - actual
        };
        assert!(delta <= tolerance, "{}: {} vs {}", message, actual, expected);
    }

    fn owner() -> ContractAddress {
        contract_address_const::<'owner'>()
    }

    fn manager() -> ContractAddress {
        contract_address_const::<'manager'>()
    }

    fn alice() -> ContractAddress {
        contract_address_const::<'alice'>()
    }

    #[derive(Copy, Drop)]
    struct Env {
        oracle: IOracleV2Dispatcher,
        price_oracle: IOracleDispatcher,
        pragma: IMockPragmaOracleDispatcher,
        summary: IMockPragmaSummaryDispatcher,
    }

    fn setup() -> Env {
        start_cheat_block_timestamp_global(START_TIME);
        let pragma = IMockPragmaOracleDispatcher { contract_address: deploy_contract("MockPragmaOracle") };
        let summary = IMockPragmaSummaryDispatcher { contract_address: deploy_contract("MockPragmaSummary") };
        let address = deploy_with_args(
            "OracleV2", array![owner().into(), manager().into(), pragma.contract_address.into(), TIMELOCK.into()],
        );
        Env {
            oracle: IOracleV2Dispatcher { contract_address: address },
            price_oracle: IOracleDispatcher { contract_address: address },
            pragma,
            summary,
        }
    }

    fn deploy_feed(decimals: u8, answer: u128) -> IMockChainlinkFeedDispatcher {
        IMockChainlinkFeedDispatcher {
            contract_address: deploy_with_args("MockChainlinkFeed", array![decimals.into(), answer.into()]),
        }
    }

    fn deploy_wrapper(asset: ContractAddress, decimals: u8, assets_per_share: u256) -> IMockERC4626Dispatcher {
        IMockERC4626Dispatcher {
            contract_address: deploy_with_args(
                "MockERC4626",
                array![asset.into(), decimals.into(), assets_per_share.low.into(), assets_per_share.high.into()],
            ),
        }
    }

    fn chainlink_config(feed: ContractAddress, max_staleness: u64, quote_asset: ContractAddress) -> ChainlinkConfig {
        ChainlinkConfig { feed, feed_decimals: 0, max_staleness, quote_asset }
    }

    fn scaled_config(
        base_asset: ContractAddress, wrapper: ContractAddress, max_growth_per_second: u128, max_rate: u128,
    ) -> ScaledConfig {
        ScaledConfig {
            base_asset,
            wrapper,
            share_decimals: 0,
            underlying_decimals: 0,
            ref_rate: 0,
            ref_timestamp: 0,
            max_growth_per_second,
            min_rate_ratio: 990_000_000_000_000_000, // 0.99
            max_rate,
        }
    }

    fn ekubo_config(extension: ContractAddress, quote_asset: ContractAddress, window: u64) -> EkuboConfig {
        EkuboConfig {
            oracle_extension: extension,
            quote_asset,
            base_decimals: 0,
            quote_decimals: 0,
            window,
            max_spot_deviation: 10 * PERCENT.try_into().unwrap(),
        }
    }

    fn add_chainlink(env: Env, asset: ContractAddress, config: ChainlinkConfig) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.add_chainlink_asset(asset, config);
    }

    fn add_scaled(env: Env, asset: ContractAddress, config: ScaledConfig) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.add_scaled_asset(asset, config);
    }

    fn add_ekubo(env: Env, asset: ContractAddress, config: EkuboConfig) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.add_ekubo_asset(asset, config);
    }

    fn add_pragma(env: Env, asset: ContractAddress, config: OracleConfig) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.add_pragma_asset(asset, config);
    }

    /// USD denominated 8 decimal feed and a matching terminal route, the base of most fixtures
    fn setup_usd_asset(env: Env, decimals: u32, answer: u128) -> (ContractAddress, IMockChainlinkFeedDispatcher) {
        let asset = deploy_asset_with_decimals(alice(), decimals).contract_address;
        let feed = deploy_feed(8, answer);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        (asset, feed)
    }

    // ------------------------------------------------------------------------------------------
    // §11.1 Chainlink leg
    // ------------------------------------------------------------------------------------------

    #[test]
    fn test_chainlink_scales_answer_to_scale() {
        let env = setup();
        // 8 decimal feed reporting 3000.00000000
        let (asset, _) = setup_usd_asset(env, 18, 300_000_000_000);
        let price = env.price_oracle.price(asset);
        assert!(price.value == 3000 * SCALE, "8-decimal feed not scaled to SCALE");
        assert!(price.is_valid, "price should be valid");

        // an 18 decimal feed reporting the same price scales identically
        let other = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(18, 3000_000_000_000_000_000_000);
        add_chainlink(env, other, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        assert!(env.price_oracle.price(other).value == 3000 * SCALE, "18-decimal feed not scaled to SCALE");
    }

    #[test]
    fn test_chainlink_staleness_boundary() {
        let env = setup();
        let (asset, feed) = setup_usd_asset(env, 18, 100_000_000);

        // exactly at the bound is still valid
        feed.set_updated_at(START_TIME);
        start_cheat_block_timestamp_global(START_TIME + 3600);
        assert!(env.price_oracle.price(asset).is_valid, "price at the staleness bound should be valid");

        // one second past it is not
        start_cheat_block_timestamp_global(START_TIME + 3601);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "price past the staleness bound should be invalid");
        assert!(price.value == SCALE, "a stale price is still reported, only flagged");
    }

    #[test]
    fn test_chainlink_disabled_staleness_check() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 0, Zero::zero()));

        feed.set_updated_at(START_TIME);
        start_cheat_block_timestamp_global(START_TIME + 10 * 86400);
        assert!(env.price_oracle.price(asset).is_valid, "max_staleness == 0 disables the check");
    }

    #[test]
    fn test_chainlink_future_updated_at_is_clamped() {
        let env = setup();
        let (asset, feed) = setup_usd_asset(env, 18, 100_000_000);

        feed.set_updated_at(START_TIME + 10_000);
        let price = env.price_oracle.price(asset);
        assert!(price.is_valid, "future dated updated_at must clamp the delta to 0");
        assert!(price.value == SCALE, "price not returned");
    }

    #[test]
    fn test_chainlink_zero_answer_is_invalid() {
        let env = setup();
        let (asset, feed) = setup_usd_asset(env, 18, 100_000_000);

        feed.set_answer(0);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "zero answer must be invalid");
        assert!(price.value == 0, "zero answer must not report a value");
    }

    #[test]
    fn test_chainlink_incomplete_round_is_invalid() {
        let env = setup();
        let (asset, feed) = setup_usd_asset(env, 18, 100_000_000);

        feed.set_updated_at(0);
        assert!(!env.price_oracle.price(asset).is_valid, "updated_at == 0 must be invalid");
    }

    // ------------------------------------------------------------------------------------------
    // §11.2 Shadow parity: the legacy Pragma kind reproduces `oracle.cairo`
    // ------------------------------------------------------------------------------------------

    fn deploy_legacy_oracle(env: Env) -> IPragmaOracleDispatcher {
        IPragmaOracleDispatcher {
            contract_address: deploy_with_args(
                "Oracle",
                array![
                    owner().into(),
                    manager().into(),
                    env.pragma.contract_address.into(),
                    env.summary.contract_address.into(),
                ],
            ),
        }
    }

    fn assert_shadow_parity(env: Env, legacy: IPragmaOracleDispatcher, asset: ContractAddress, message: ByteArray) {
        let new_price = env.price_oracle.price(asset);
        let old_price = IOracleDispatcher { contract_address: legacy.contract_address }.price(asset);
        assert!(new_price.value == old_price.value, "{}: value mismatch", message);
        assert!(new_price.is_valid == old_price.is_valid, "{}: validity mismatch", message);
    }

    #[test]
    fn test_shadow_parity_with_legacy_oracle() {
        let env = setup();
        let legacy = deploy_legacy_oracle(env);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;

        let config = OracleConfig {
            pragma_key: PRAGMA_KEY,
            timeout: 3600,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median,
        };
        add_pragma(env, asset, config);
        cheat_caller_address(legacy.contract_address, manager(), CheatSpan::TargetCalls(1));
        legacy.add_asset(asset, config);

        env.pragma.set_price(PRAGMA_KEY, 2 * SCALE.try_into().unwrap());
        env.pragma.set_last_updated_timestamp(PRAGMA_KEY, START_TIME);
        assert_shadow_parity(env, legacy, asset, "fresh price");
        assert!(env.price_oracle.price(asset).value == 2 * SCALE, "price not scaled");

        // stale
        start_cheat_block_timestamp_global(START_TIME + 3601);
        assert_shadow_parity(env, legacy, asset, "stale price");
        assert!(!env.price_oracle.price(asset).is_valid, "stale price should be invalid");
        start_cheat_block_timestamp_global(START_TIME);

        // too few sources
        env.pragma.set_num_sources_aggregated(PRAGMA_KEY, 1);
        assert_shadow_parity(env, legacy, asset, "insufficient sources");
        assert!(!env.price_oracle.price(asset).is_valid, "insufficient sources should be invalid");
        env.pragma.set_num_sources_aggregated(PRAGMA_KEY, 2);

        // zero price
        env.pragma.set_price(PRAGMA_KEY, 0);
        assert_shadow_parity(env, legacy, asset, "zero price");
        assert!(!env.price_oracle.price(asset).is_valid, "zero price should be invalid");
    }

    /// The one deliberate divergence from `oracle.cairo`: it accepts a summary-stats TWAP config and
    /// this router does not implement that path at all. The config is rejected at write time rather
    /// than ignored, so an asset cannot end up reading spot through a config that says TWAP. Migrating
    /// such an asset (§10, step 1) means zeroing both fields and accepting the spot answer.
    #[test]
    #[should_panic(expected: "pragma-twap-not-supported")]
    fn test_pragma_twap_config_is_rejected() {
        let env = setup();
        let legacy = deploy_legacy_oracle(env);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;

        let config = OracleConfig {
            pragma_key: PRAGMA_KEY,
            timeout: 3600,
            number_of_sources: 2,
            start_time_offset: 100,
            time_window: 50,
            aggregation_mode: AggregationMode::Median,
        };
        // the legacy oracle takes it, which is what makes the divergence worth pinning
        cheat_caller_address(legacy.contract_address, manager(), CheatSpan::TargetCalls(1));
        legacy.add_asset(asset, config);

        add_pragma(env, asset, config);
    }

    #[test]
    #[should_panic(expected: "pragma-twap-not-supported")]
    fn test_pragma_twap_config_is_rejected_on_a_route_change_too() {
        let env = setup();
        let asset = setup_pragma_asset(env, pragma_config_with(3600, 2));
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .propose_pragma_route(
                asset,
                OracleConfig {
                    pragma_key: PRAGMA_KEY,
                    timeout: 3600,
                    number_of_sources: 2,
                    start_time_offset: 100,
                    time_window: 50,
                    aggregation_mode: AggregationMode::Median,
                },
            );
    }

    #[test]
    fn test_unconfigured_asset_is_invalid_not_reverting() {
        let env = setup();
        // the legacy oracle reverts here with "invalid-pragma-key"; the router reports invalid,
        // which pool.add_asset still refuses to list
        let price = env.price_oracle.price(contract_address_const::<'unknown'>());
        assert!(!price.is_valid, "unconfigured asset must be invalid");
        assert!(price.value == 0, "unconfigured asset must have no value");
    }

    // ------------------------------------------------------------------------------------------
    // §11.3 Scaled leg
    // ------------------------------------------------------------------------------------------

    #[test]
    fn test_scaled_matching_decimals() {
        let env = setup();
        // underlying at $2, wrapper worth 1.1 underlying
        let (underlying, _) = setup_usd_asset(env, 18, 200_000_000);
        let wrapper = deploy_wrapper(underlying, 18, 1_100_000_000_000_000_000);
        let asset = wrapper.contract_address;
        add_scaled(env, asset, scaled_config(underlying, asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()));

        let (rate, rate_is_valid) = env.oracle.conversion_rate(asset);
        assert!(rate == 1_100_000_000_000_000_000, "conversion rate not normalised to SCALE");
        assert!(rate_is_valid, "conversion rate should be within bounds");

        let price = env.price_oracle.price(asset);
        assert!(price.value == 2 * SCALE * 11 / 10, "composed price incorrect");
        assert!(price.is_valid, "composed price should be valid");
    }

    #[test]
    fn test_scaled_mismatched_decimals() {
        let env = setup();
        // 8 decimal underlying at $100_000, 18 decimal share worth 1.02 underlying.
        // Normalising by the share decimals instead of the underlying decimals would understate
        // the rate by 10^10 — this is the case no live wrapper would catch.
        let (underlying, _) = setup_usd_asset(env, 8, 10_000_000_000_000);
        let wrapper = deploy_wrapper(underlying, 18, 102_000_000);
        let asset = wrapper.contract_address;
        add_scaled(env, asset, scaled_config(underlying, asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()));

        let (rate, _) = env.oracle.conversion_rate(asset);
        assert!(rate == 1_020_000_000_000_000_000, "rate must be normalised by the underlying decimals");

        let price = env.price_oracle.price(asset);
        assert!(price.value == 102_000 * SCALE, "composed price incorrect");
        assert!(price.is_valid, "composed price should be valid");
    }

    #[test]
    fn test_scaled_invalid_base_leg_invalidates_price() {
        let env = setup();
        let (underlying, feed) = setup_usd_asset(env, 18, 200_000_000);
        let wrapper = deploy_wrapper(underlying, 18, 1_100_000_000_000_000_000);
        let asset = wrapper.contract_address;
        add_scaled(env, asset, scaled_config(underlying, asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()));

        feed.set_updated_at(START_TIME - 7200);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a stale base leg must invalidate the composed price");
    }

    // ------------------------------------------------------------------------------------------
    // Per-leg validation. `compose` is `ratio_is_valid && quote.is_valid && value != 0`, and the two
    // legs are checked by different code against different parameters: the ratio leg by its own kind's
    // rules, the quote leg by `price_terminal` running the quote asset's own full check set. Each of
    // the three composite kinds therefore needs both directions exercised, or a leg whose checks are
    // silently skipped would still look correct in every other test.
    // ------------------------------------------------------------------------------------------

    /// The EkuboTwap quote leg. `test_ekubo_over_non_terminal_quote_is_invalid` covers a quote asset
    /// that is the wrong *shape*; this covers one that is the right shape and simply failing, which is
    /// the case that actually happens in production.
    #[test]
    fn test_ekubo_invalid_quote_leg_invalidates_price() {
        let env = setup();
        let (eth, eth_feed) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        extension.set_earliest_observation_time(START_TIME - 2 * MIN_TWAP_WINDOW);
        extension.set_price_x128(MIN_TWAP_WINDOW, TWO_POW_128 / 1024);
        add_ekubo(env, asset, ekubo_config(extension.contract_address, eth, MIN_TWAP_WINDOW));
        assert!(env.price_oracle.price(asset).is_valid, "price should start out valid");

        // the TWAP leg is untouched and still perfectly valid on its own
        eth_feed.set_updated_at(START_TIME - 7200);
        let (ratio, ratio_is_valid) = env.oracle.twap(asset, MIN_TWAP_WINDOW);
        assert!(ratio_is_valid && ratio == SCALE / 1024, "the ratio leg must be unaffected");

        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a stale quote leg must invalidate the composed price");
        // a stale leg still surfaces its last value, so the composed value is non-zero here — what
        // section 3.3 forbids is it ever being the *bare ratio*, i.e. a pool ratio read as a USD price
        assert!(price.value != ratio, "the bare TWAP ratio must never be reported as a USD price");
        assert!(price.value == ratio * env.price_oracle.price(eth).value / SCALE, "composition still applies");

        // a zero-answer quote leg fails a different check on the same leg, and does zero the value
        eth_feed.set_updated_at(START_TIME);
        eth_feed.set_answer(0);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a zero quote leg must invalidate the composed price");
        assert!(price.value == 0, "a zero quote leg must not report a value");
    }

    /// Both legs of a composed *Chainlink* route, deterministically. Each leg carries its own
    /// `max_staleness`, so the two are checked against different bounds — a composite that inherited
    /// its quote asset's bound, or applied only one of the two, would pass a single-sided test.
    #[test]
    fn test_chainlink_composed_legs_are_checked_independently() {
        let env = setup();
        // ETH/USD at $3000 on a 1h bound, and a wstETH/ETH style feed at 1.2 ETH on a 25h bound
        let (eth, eth_feed) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let ratio_feed = deploy_feed(8, 120_000_000);
        add_chainlink(env, asset, chainlink_config(ratio_feed.contract_address, 90000, eth));
        assert!(env.price_oracle.price(asset).value == 3600 * SCALE, "price should start out composed");

        // the ratio leg may be far older than the quote leg tolerates, and still be fine
        ratio_feed.set_updated_at(START_TIME - 80000);
        assert!(env.price_oracle.price(asset).is_valid, "the ratio leg must use its own 25h bound");

        // past its own bound it invalidates, while the quote leg is untouched
        ratio_feed.set_updated_at(START_TIME - 90001);
        assert!(!env.price_oracle.price(asset).is_valid, "a stale ratio leg must invalidate the composition");
        assert!(env.price_oracle.price(eth).is_valid, "the quote leg must be unaffected");

        // conversely: a fresh ratio leg and a stale quote leg
        ratio_feed.set_updated_at(START_TIME);
        eth_feed.set_updated_at(START_TIME - 7200);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a stale quote leg must invalidate the composition");
        // as above: stale surfaces a value, and the value is never the bare ratio
        assert!(price.value != SCALE * 12 / 10, "the bare wstETH/ETH style ratio must never be a USD price");

        // each leg's own non-zero check, too
        eth_feed.set_updated_at(START_TIME);
        ratio_feed.set_answer(0);
        assert!(!env.price_oracle.price(asset).is_valid, "a zero ratio leg must invalidate");
        ratio_feed.set_answer(120_000_000);
        eth_feed.set_answer(0);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a zero quote leg must invalidate");
        assert!(price.value == 0, "a zero quote leg must not report a value");
    }

    /// A quote asset that is deactivated (§7) prices `{ 0, false }`, so every composite standing on it
    /// must go invalid rather than read through to a zero. Covered for all three composite kinds at
    /// once, since they share `compose`.
    #[test]
    fn test_deactivating_a_quote_asset_invalidates_every_composite_on_it() {
        let env = setup();
        let (base, _) = setup_usd_asset(env, 18, 200_000_000);

        // a Scaled route over `base`
        let wrapper = deploy_wrapper(base, 18, 1_100_000_000_000_000_000);
        let scaled_asset = wrapper.contract_address;
        add_scaled(
            env, scaled_asset, scaled_config(base, scaled_asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );

        // an EkuboTwap route quoted in `base`
        let ekubo_asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        extension.set_earliest_observation_time(START_TIME - 2 * MIN_TWAP_WINDOW);
        extension.set_price_x128(MIN_TWAP_WINDOW, TWO_POW_128 / 1024);
        add_ekubo(env, ekubo_asset, ekubo_config(extension.contract_address, base, MIN_TWAP_WINDOW));

        // a composed Chainlink route quoted in `base`
        let chainlink_asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let ratio_feed = deploy_feed(8, 120_000_000);
        add_chainlink(env, chainlink_asset, chainlink_config(ratio_feed.contract_address, 3600, base));

        for asset in array![scaled_asset, ekubo_asset, chainlink_asset] {
            assert!(env.price_oracle.price(asset).is_valid, "every composite must start out valid");
        }

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_none_route(base);
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(base);
        assert!(!env.price_oracle.price(base).is_valid, "the quote asset is deactivated");

        for asset in array![scaled_asset, ekubo_asset, chainlink_asset] {
            let price = env.price_oracle.price(asset);
            assert!(!price.is_valid, "a composite over a deactivated quote asset must be invalid");
            assert!(price.value == 0, "must not fall back to the bare ratio");
        }
    }

    // ------------------------------------------------------------------------------------------
    // §11.4 Composition safety
    // ------------------------------------------------------------------------------------------

    /// Repoints `asset` at a Chainlink route quoted in `quote_asset`, i.e. makes it composite.
    fn make_composite(env: Env, asset: ContractAddress, feed: ContractAddress, quote_asset: ContractAddress) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed, 3600, quote_asset));
        start_cheat_block_timestamp_global(get_block_timestamp() + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
    }

    #[test]
    fn test_scaled_over_non_terminal_base_is_invalid() {
        let env = setup();
        let (underlying, underlying_feed) = setup_usd_asset(env, 18, 200_000_000);
        let (usd_asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, 1_100_000_000_000_000_000);
        let asset = wrapper.contract_address;
        add_scaled(env, asset, scaled_config(underlying, asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()));
        assert!(env.price_oracle.price(asset).is_valid, "price should start out valid");

        // the base asset's own route is changed to a composite one after the fact
        make_composite(env, underlying, underlying_feed.contract_address, usd_asset);

        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a non-terminal base leg must invalidate the price");
        assert!(price.value == 0, "must not fall back to the bare ratio");
        // the underlying itself still prices, one level of composition is allowed
        assert!(env.price_oracle.price(underlying).is_valid, "one level of composition must still work");
    }

    #[test]
    fn test_ekubo_over_non_terminal_quote_is_invalid() {
        let env = setup();
        let (quote, quote_feed) = setup_usd_asset(env, 18, 300_000_000_000);
        let (usd_asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        extension.set_earliest_observation_time(START_TIME - 2 * MIN_TWAP_WINDOW);
        extension.set_price_x128(MIN_TWAP_WINDOW, TWO_POW_128 / 1024);
        add_ekubo(env, asset, ekubo_config(extension.contract_address, quote, MIN_TWAP_WINDOW));
        assert!(env.price_oracle.price(asset).is_valid, "price should start out valid");

        make_composite(env, quote, quote_feed.contract_address, usd_asset);

        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a non-terminal quote leg must invalidate the price");
        assert!(price.value == 0, "must not fall back to the bare TWAP ratio");
    }

    /// The third composite kind. A `Chainlink` route is terminal or composite depending on its
    /// *config*, not its kind, so a composed feed's quote leg can be made non-terminal after the fact
    /// — `assert_terminal_route` only runs at write time, and the quote asset's own route can change
    /// afterwards. The guarantee therefore has to be structural, and this is the Chainlink case of it.
    ///
    /// Live relevance: wstETH is a composed Chainlink route over ETH. If ETH were ever repointed to a
    /// composed config, wstETH would stop pricing — which is the correct outcome, but an operational
    /// coupling worth having pinned.
    #[test]
    fn test_chainlink_over_non_terminal_quote_is_invalid() {
        let env = setup();
        let (quote, quote_feed) = setup_usd_asset(env, 18, 300_000_000_000);
        let (usd_asset, _) = setup_usd_asset(env, 18, 100_000_000);

        // a wstETH/ETH shaped feed composed over a terminal quote asset
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 120_000_000);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, quote));
        assert!(env.price_oracle.price(asset).value == 3600 * SCALE, "price should start out composed");

        // now the quote asset itself becomes composite, one level too deep
        make_composite(env, quote, quote_feed.contract_address, usd_asset);

        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a non-terminal quote leg must invalidate the price");
        assert!(price.value == 0, "must not fall back to the bare ratio");
        // the quote asset still prices on its own; only its use as a leg is refused
        assert!(env.price_oracle.price(quote).is_valid, "one level of composition must still work");
    }

    #[test]
    fn test_mutually_quoting_routes_terminate() {
        let env = setup();
        let (first, first_feed) = setup_usd_asset(env, 18, 200_000_000);
        let (second, second_feed) = setup_usd_asset(env, 18, 400_000_000);

        // second quotes first, which configuration allows since first is terminal
        make_composite(env, second, second_feed.contract_address, first);
        // first is then made to quote second. Configuration refuses this ("quote-asset-not-terminal"),
        // so the cycle is written straight to storage: the guarantee under test is structural, not a
        // config time check that a later change or a botched upgrade could bypass.
        store(
            env.oracle.contract_address,
            map_entry_address(selector!("chainlink_configs"), array![first.into()].span()),
            array![first_feed.contract_address.into(), 8, 3600, second.into()].span(),
        );

        // both resolve to invalid without recursing
        assert!(!env.price_oracle.price(first).is_valid, "mutual quoting must not resolve");
        assert!(!env.price_oracle.price(second).is_valid, "mutual quoting must not resolve");
        assert!(env.price_oracle.price(first).value == 0, "must not fall back to the bare ratio");
    }

    #[test]
    fn test_chainlink_non_usd_feed_composes_once() {
        let env = setup();
        // ETH/USD at $3000, and a wstETH/ETH style feed at 1.2 ETH
        let (eth, _) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 120_000_000);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, eth));

        let price = env.price_oracle.price(asset);
        assert!(price.value == 3600 * SCALE, "non-USD feed not composed with its quote asset");
        assert!(price.is_valid, "composed price should be valid");
        // as a quote leg it is not terminal
        assert!(!env.oracle.price_terminal(asset).is_valid, "a composite route is not a terminal route");
    }

    // ------------------------------------------------------------------------------------------
    // §11.5 Quote leg mandatory
    // ------------------------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: "invalid-zero-quote-asset")]
    fn test_ekubo_route_requires_quote_asset() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        add_ekubo(env, asset, ekubo_config(extension.contract_address, Zero::zero(), MIN_TWAP_WINDOW));
    }

    #[test]
    #[should_panic(expected: "invalid-zero-base-asset")]
    fn test_scaled_route_requires_base_asset() {
        let env = setup();
        let underlying = deploy_asset_with_decimals(alice(), 18).contract_address;
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        add_scaled(
            env,
            wrapper.contract_address,
            scaled_config(Zero::zero(), wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
    }

    #[test]
    #[should_panic(expected: "quote-asset-not-terminal")]
    fn test_quote_asset_must_be_routed() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, contract_address_const::<'none'>()));
    }

    #[test]
    #[should_panic(expected: "self-referential-quote-asset")]
    fn test_quote_asset_cannot_be_the_asset_itself() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, asset));
    }

    #[test]
    #[should_panic(expected: "wrapper-underlying-mismatch")]
    fn test_scaled_route_checks_wrapper_underlying() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 200_000_000);
        let (other, _) = setup_usd_asset(env, 18, 200_000_000);
        let wrapper = deploy_wrapper(other, 18, SCALE);
        add_scaled(
            env,
            wrapper.contract_address,
            scaled_config(underlying, wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
    }

    // ------------------------------------------------------------------------------------------
    // §11.6 Rate bounds and anchors
    // ------------------------------------------------------------------------------------------

    fn setup_scaled(env: Env, max_growth_per_second: u128) -> (ContractAddress, IMockERC4626Dispatcher) {
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        let asset = wrapper.contract_address;
        add_scaled(env, asset, scaled_config(underlying, asset, max_growth_per_second, 2 * SCALE.try_into().unwrap()));
        (asset, wrapper)
    }

    #[test]
    fn test_rate_upper_bound_boundary() {
        let env = setup();
        let growth: u128 = 1_000_000_000_000; // 1e12 [SCALE/s]
        let (asset, wrapper) = setup_scaled(env, growth);

        let elapsed: u128 = 1000;
        start_cheat_block_timestamp_global(START_TIME + elapsed.try_into().unwrap());

        // exactly on the cone
        wrapper.set_assets_per_share((SCALE.try_into().unwrap() + growth * elapsed).into());
        assert!(env.price_oracle.price(asset).is_valid, "rate on the upper bound must be valid");

        // one wei above it
        wrapper.set_assets_per_share((SCALE.try_into().unwrap() + growth * elapsed + 1).into());
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "rate above the upper bound must be invalid");
        // as with a stale feed, the value is still surfaced; only the flag decides
        assert!(price.value != 0, "the observed value is still reported");
    }

    #[test]
    fn test_rate_lower_bound_boundary() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);

        // exactly at min_rate_ratio (0.99) of the anchor
        wrapper.set_assets_per_share(990_000_000_000_000_000);
        assert!(env.price_oracle.price(asset).is_valid, "rate on the lower bound must be valid");

        // just below it
        wrapper.set_assets_per_share(989_999_999_999_999_999);
        assert!(!env.price_oracle.price(asset).is_valid, "rate below the lower bound must be invalid");

        // a one wei dip below parity is tolerated: a hard parity floor would freeze the market
        wrapper.set_assets_per_share(SCALE - 1);
        assert!(env.price_oracle.price(asset).is_valid, "a one wei dip below parity must not invalidate");
    }

    #[test]
    fn test_rate_max_rate_caps_the_cone() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);

        // far enough in the future that the cone would allow anything
        start_cheat_block_timestamp_global(START_TIME + 10_000_000);
        wrapper.set_assets_per_share(2 * SCALE);
        assert!(env.price_oracle.price(asset).is_valid, "rate at max_rate must be valid");

        wrapper.set_assets_per_share(2 * SCALE + 1);
        assert!(!env.price_oracle.price(asset).is_valid, "rate above max_rate must be invalid");
    }

    /// The anchor refresh is manager only. It is not permissionless because each refresh restates
    /// the floor as `ref_rate * min_rate_ratio`: repeated refreshes walk the floor down
    /// multiplicatively, and there is no `min_rate` to stop that the way `max_rate` caps the ceiling.
    #[test]
    fn test_reanchor_tightens_the_bound() {
        let env = setup();
        let growth: u128 = 1_000_000_000_000;
        let (asset, wrapper) = setup_scaled(env, growth);

        start_cheat_block_timestamp_global(START_TIME + 1000);
        let rate: u256 = (SCALE.try_into().unwrap() + growth * 500).into();
        wrapper.set_assets_per_share(rate);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(asset);

        let config = env.oracle.scaled_config(asset);
        assert!(config.ref_rate.into() == rate, "anchor not refreshed");
        assert!(config.ref_timestamp == START_TIME + 1000, "anchor timestamp not refreshed");

        // the cone now starts from the new anchor: a rate the old cone allowed is out of bounds
        wrapper.set_assets_per_share((SCALE.try_into().unwrap() + growth * 1000).into());
        assert!(!env.price_oracle.price(asset).is_valid, "the refreshed anchor must tighten the ceiling");
        wrapper.set_assets_per_share(config.ref_rate.into());
        assert!(env.price_oracle.price(asset).is_valid, "the anchor itself is within bounds");
    }

    /// The floor is a real bound only while re-anchoring is reviewed: five 1% steps walk it below a
    /// 5% loss that the cone rejects outright in one step. This is what the manager gate buys.
    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_anchor_refresh_cannot_be_walked_down_by_anyone() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);

        // a 5% loss is out of bounds in one step
        wrapper.set_assets_per_share(950_000_000_000_000_000);
        assert!(!env.price_oracle.price(asset).is_valid, "5% drop should be invalid");

        // and the 1% step that would start walking the floor down is not available to alice
        wrapper.set_assets_per_share(990_000_000_000_000_000);
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(asset);
    }

    #[test]
    fn test_reanchor_takes_the_wrapper_rate() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);

        // a rate the cone rejects; only the manager can re-accept it, and only as reported
        wrapper.set_assets_per_share(1_500_000_000_000_000_000);
        assert!(!env.price_oracle.price(asset).is_valid, "rate should be out of bounds");

        start_cheat_block_timestamp_global(START_TIME + 60);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(asset);

        let config = env.oracle.scaled_config(asset);
        assert!(config.ref_rate == 1_500_000_000_000_000_000, "anchor must be the wrapper reported rate");
        assert!(env.price_oracle.price(asset).is_valid, "price valid again after re-anchoring");
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_reanchor_is_manager_only() {
        let env = setup();
        let (asset, _) = setup_scaled(env, 1_000_000_000_000);
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(asset);
    }

    #[test]
    #[should_panic(expected: "anchor-rate-below-parity")]
    fn test_scaled_route_rejects_anchor_below_parity() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE - 1);
        add_scaled(
            env,
            wrapper.contract_address,
            scaled_config(underlying, wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
    }

    // ------------------------------------------------------------------------------------------
    // Configuration validation. Every write-time guardrail, because these are what keep a source
    // that cannot be made safe on the read path out of a route in the first place (§3.4, §3.5).
    // ------------------------------------------------------------------------------------------

    fn deploy_wide_token(decimals: u8) -> ContractAddress {
        deploy_with_args("MockWideDecimalsToken", array![decimals.into()])
    }

    #[test]
    #[should_panic(expected: "invalid-zero-asset")]
    fn test_listing_rejects_a_zero_asset() {
        let env = setup();
        let feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, Zero::zero(), chainlink_config(feed.contract_address, 3600, Zero::zero()));
    }

    #[test]
    #[should_panic(expected: "invalid-zero-feed")]
    fn test_chainlink_route_requires_a_feed() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        add_chainlink(env, asset, chainlink_config(Zero::zero(), 3600, Zero::zero()));
    }

    #[test]
    #[should_panic(expected: "invalid-zero-wrapper")]
    fn test_scaled_route_requires_a_wrapper() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        add_scaled(
            env, asset, scaled_config(underlying, Zero::zero(), 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
    }

    #[test]
    #[should_panic(expected: "invalid-zero-oracle-extension")]
    fn test_ekubo_route_requires_an_extension() {
        let env = setup();
        let (eth, _) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        add_ekubo(env, asset, ekubo_config(Zero::zero(), eth, MIN_TWAP_WINDOW));
    }

    #[test]
    #[should_panic(expected: "self-referential-base-asset")]
    fn test_scaled_route_rejects_a_self_referential_base_asset() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        let asset = wrapper.contract_address;
        add_scaled(env, asset, scaled_config(asset, asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()));
    }

    #[test]
    #[should_panic(expected: "invalid-min-rate-ratio")]
    fn test_scaled_route_rejects_a_zero_min_rate_ratio() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        let mut config = scaled_config(
            underlying, wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap(),
        );
        config.min_rate_ratio = 0;
        add_scaled(env, wrapper.contract_address, config);
    }

    /// A ratio above SCALE would put the floor above the anchor, so the route would be invalid from
    /// the moment it is listed.
    #[test]
    #[should_panic(expected: "invalid-min-rate-ratio")]
    fn test_scaled_route_rejects_a_min_rate_ratio_above_parity() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        let mut config = scaled_config(
            underlying, wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap(),
        );
        config.min_rate_ratio = SCALE.try_into().unwrap() + 1;
        add_scaled(env, wrapper.contract_address, config);
    }

    #[test]
    #[should_panic(expected: "share-decimals-out-of-range")]
    fn test_scaled_route_rejects_wide_share_decimals() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 100, SCALE);
        add_scaled(
            env,
            wrapper.contract_address,
            scaled_config(underlying, wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
    }

    #[test]
    #[should_panic(expected: "underlying-decimals-out-of-range")]
    fn test_scaled_route_rejects_wide_underlying_decimals() {
        let env = setup();
        let underlying = deploy_wide_token(100);
        let feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, underlying, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        add_scaled(
            env,
            wrapper.contract_address,
            scaled_config(underlying, wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
    }

    #[test]
    #[should_panic(expected: "base-decimals-out-of-range")]
    fn test_ekubo_route_rejects_wide_base_decimals() {
        let env = setup();
        let (eth, _) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_wide_token(100);
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        add_ekubo(env, asset, ekubo_config(extension.contract_address, eth, MIN_TWAP_WINDOW));
    }

    #[test]
    #[should_panic(expected: "quote-decimals-out-of-range")]
    fn test_ekubo_route_rejects_wide_quote_decimals() {
        let env = setup();
        let quote = deploy_wide_token(100);
        let feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, quote, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        add_ekubo(env, asset, ekubo_config(extension.contract_address, quote, MIN_TWAP_WINDOW));
    }

    /// The constructor's own message is wrapped by the deployment failure, so these three assert on
    /// the failure rather than on the text. `setup()` is the positive control: it deploys the same
    /// contract with all three arguments non-zero in every other test in this file.
    #[test]
    #[should_panic]
    fn test_constructor_rejects_a_zero_manager() {
        let pragma = deploy_contract("MockPragmaOracle");
        deploy_with_args("OracleV2", array![owner().into(), Zero::zero(), pragma.into(), TIMELOCK.into()]);
    }

    // ------------------------------------------------------------------------------------------
    // §8 Legacy Pragma kind. It reproduces `oracle.cairo`'s semantics with isolated reads, so each
    // of that contract's validity rules has to hold here too — and fail closed rather than revert.
    // ------------------------------------------------------------------------------------------

    fn pragma_config_with(timeout: u64, number_of_sources: u32) -> OracleConfig {
        OracleConfig {
            pragma_key: PRAGMA_KEY,
            timeout,
            number_of_sources,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median,
        }
    }

    fn setup_pragma_asset(env: Env, config: OracleConfig) -> ContractAddress {
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        env.pragma.set_price(PRAGMA_KEY, 2 * SCALE.try_into().unwrap());
        add_pragma(env, asset, config);
        asset
    }

    #[test]
    fn test_pragma_staleness_is_enforced_and_can_be_disabled() {
        let env = setup();
        let asset = setup_pragma_asset(env, pragma_config_with(3600, 2));
        assert!(env.price_oracle.price(asset).is_valid, "price not set up");

        env.pragma.set_last_updated_timestamp(PRAGMA_KEY, START_TIME - 3600);
        assert!(env.price_oracle.price(asset).is_valid, "exactly at the timeout must still be valid");
        env.pragma.set_last_updated_timestamp(PRAGMA_KEY, START_TIME - 3601);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "past the timeout must be invalid");
        // as elsewhere, the observed value is still surfaced; only the flag decides
        assert!(price.value == 2 * SCALE, "the stale value is still reported");

        // a zero timeout disables the check
        let fresh = setup_pragma_asset(env, pragma_config_with(0, 2));
        env.pragma.set_last_updated_timestamp(PRAGMA_KEY, 1);
        assert!(env.price_oracle.price(fresh).is_valid, "a zero timeout must disable the staleness check");
    }

    #[test]
    fn test_pragma_future_updated_at_is_clamped() {
        let env = setup();
        let asset = setup_pragma_asset(env, pragma_config_with(3600, 2));
        env.pragma.set_last_updated_timestamp(PRAGMA_KEY, START_TIME + 10_000);
        assert!(env.price_oracle.price(asset).is_valid, "a future timestamp must clamp to a zero delta");
    }

    #[test]
    fn test_pragma_source_count_is_enforced() {
        let env = setup();
        let asset = setup_pragma_asset(env, pragma_config_with(3600, 5));

        env.pragma.set_num_sources_aggregated(PRAGMA_KEY, 5);
        assert!(env.price_oracle.price(asset).is_valid, "exactly the required sources must be valid");
        env.pragma.set_num_sources_aggregated(PRAGMA_KEY, 4);
        assert!(!env.price_oracle.price(asset).is_valid, "too few sources must be invalid");
    }

    #[test]
    fn test_pragma_zero_price_is_invalid() {
        let env = setup();
        let asset = setup_pragma_asset(env, pragma_config_with(3600, 2));
        env.pragma.set_price(PRAGMA_KEY, 0);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid && price.value == 0, "a zero Pragma price must be invalid");
    }

    /// The legacy reads are syscall-isolated too, so a Pragma oracle that does not answer `get_data`
    /// degrades rather than reverting — which is the one behavioural difference from `oracle.cairo`
    /// that matters for liveness.
    #[test]
    fn test_absent_pragma_oracle_is_invalid_not_reverting() {
        start_cheat_block_timestamp_global(START_TIME);
        let not_a_pragma = deploy_contract("MockMalformedFeed");
        let address = deploy_with_args(
            "OracleV2", array![owner().into(), manager().into(), not_a_pragma.into(), TIMELOCK.into()],
        );
        let oracle = IOracleV2Dispatcher { contract_address: address };
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        cheat_caller_address(address, manager(), CheatSpan::TargetCalls(1));
        oracle.add_pragma_asset(asset, pragma_config_with(3600, 2));

        let price = IOracleDispatcher { contract_address: address }.price(asset);
        assert!(!price.is_valid && price.value == 0, "a source without the entrypoint must be invalid");
    }

    // ------------------------------------------------------------------------------------------
    // §11.7 Failure isolation
    // ------------------------------------------------------------------------------------------

    #[test]
    fn test_panicking_feed_is_invalid_not_reverting() {
        let env = setup();
        let (asset, feed) = setup_usd_asset(env, 18, 100_000_000);

        feed.set_should_panic(true);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a panicking source must be reported invalid");
        assert!(price.value == 0, "a panicking source must not report a value");
    }

    #[test]
    fn test_panicking_wrapper_is_invalid_not_reverting() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);

        wrapper.set_should_panic(true);
        assert!(!env.price_oracle.price(asset).is_valid, "a panicking wrapper must be reported invalid");
        let (rate, is_valid) = env.oracle.conversion_rate(asset);
        assert!(rate == 0 && !is_valid, "conversion rate view must degrade too");
    }

    #[test]
    fn test_malformed_response_is_invalid_not_reverting() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_contract("MockMalformedFeed");
        add_chainlink(env, asset, chainlink_config(feed, 3600, Zero::zero()));

        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a non-deserializable response must be reported invalid");
        assert!(price.value == 0, "a non-deserializable response must not report a value");
    }

    #[test]
    fn test_wrong_contract_at_the_feed_address_is_invalid_not_reverting() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);

        // repoint the feed at a contract that does not implement the aggregator entrypoint;
        // written directly to storage because configuration would reject it
        store(
            env.oracle.contract_address,
            map_entry_address(selector!("chainlink_configs"), array![asset.into()].span()),
            array![env.pragma.contract_address.into(), 8, 3600, 0].span(),
        );

        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "a source without the entrypoint must be reported invalid");
        assert!(price.value == 0, "a source without the entrypoint must not report a value");
    }

    fn interest_rate_config() -> InterestRateConfig {
        InterestRateConfig {
            min_target_utilization: 75_000,
            max_target_utilization: 99_999,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        }
    }

    fn asset_params(asset: ContractAddress) -> AssetParams {
        AssetParams {
            asset,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        }
    }

    #[test]
    #[should_panic(expected: "oracle-price-invalid")]
    fn test_failure_surfaces_as_the_pools_own_assertion() {
        let env = setup();
        let (asset, feed) = setup_usd_asset(env, 18, 100_000_000);
        let curator = contract_address_const::<'curator'>();
        let pool = IPoolDispatcher {
            contract_address: deploy_with_args(
                "Pool", array!['PoolName', owner().into(), curator.into(), env.oracle.contract_address.into()],
            ),
        };

        feed.set_should_panic(true);
        // the source's panic does not propagate: the pool rejects the listing with its own error
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool.add_asset(asset_params(asset), interest_rate_config());
    }

    #[test]
    fn test_pool_views_do_not_revert_on_a_broken_source() {
        let env = setup();
        let (collateral, collateral_feed) = setup_usd_asset(env, 18, 100_000_000);
        let (debt, _) = setup_usd_asset(env, 18, 100_000_000);
        let curator = contract_address_const::<'curator'>();
        let pool = IPoolDispatcher {
            contract_address: deploy_with_args(
                "Pool", array!['PoolName', owner().into(), curator.into(), env.oracle.contract_address.into()],
            ),
        };

        let collateral_asset = IERC20Dispatcher { contract_address: collateral };
        let debt_asset = IERC20Dispatcher { contract_address: debt };
        cheat_caller_address(collateral, alice(), CheatSpan::TargetCalls(1));
        collateral_asset.approve(pool.contract_address, SCALE);
        cheat_caller_address(debt, alice(), CheatSpan::TargetCalls(1));
        debt_asset.approve(pool.contract_address, SCALE);
        cheat_caller_address(collateral, alice(), CheatSpan::TargetCalls(1));
        collateral_asset.transfer(curator, SCALE);
        cheat_caller_address(debt, alice(), CheatSpan::TargetCalls(1));
        debt_asset.transfer(curator, SCALE);
        cheat_caller_address(collateral, curator, CheatSpan::TargetCalls(1));
        collateral_asset.approve(pool.contract_address, SCALE);
        cheat_caller_address(debt, curator, CheatSpan::TargetCalls(1));
        debt_asset.approve(pool.contract_address, SCALE);

        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool.add_asset(asset_params(collateral), interest_rate_config());
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool.add_asset(asset_params(debt), interest_rate_config());
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool
            .set_pair_config(
                collateral,
                debt,
                PairConfig { max_ltv: (80 * PERCENT).try_into().unwrap(), liquidation_factor: 0, debt_cap: 0 },
            );

        collateral_feed.set_should_panic(true);

        // documented behaviour of check_collateralization: it returns rather than reverting when a
        // price is invalid, which only holds because the router swallowed the source's panic
        let (_, collateral_value, debt_value) = pool.check_collateralization(collateral, debt, alice());
        assert!(collateral_value == 0 && debt_value == 0, "no values should be derived from a broken source");
        assert!(!pool.price(collateral).is_valid, "the pool must see the price as invalid");
        assert!(pool.price(debt).is_valid, "the unaffected asset must still price");
    }

    // ------------------------------------------------------------------------------------------
    // §11.8 Ekubo leg
    // ------------------------------------------------------------------------------------------

    fn setup_ekubo(env: Env, window: u64) -> (ContractAddress, IMockEkuboOracleDispatcher) {
        let (eth, _) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        extension.set_earliest_observation_time(START_TIME - 2 * window);
        // 1 unit of the asset = 1/1024 ETH, a binary fraction so the scaling is exact
        extension.set_price_x128(window, TWO_POW_128 / 1024);
        add_ekubo(env, asset, ekubo_config(extension.contract_address, eth, window));
        (asset, extension)
    }

    #[test]
    fn test_ekubo_twap_composes_with_the_quote_leg() {
        let env = setup();
        let (asset, _) = setup_ekubo(env, MIN_TWAP_WINDOW);

        let (ratio, is_valid) = env.oracle.twap(asset, MIN_TWAP_WINDOW);
        assert!(ratio == SCALE / 1024, "TWAP ratio not normalised to SCALE");
        assert!(is_valid, "TWAP should be valid");

        // 1/1024 ETH at $3000
        let price = env.price_oracle.price(asset);
        assert!(price.value == 3000 * SCALE / 1024, "TWAP not composed with ETH/USD");
        assert!(price.is_valid, "composed price should be valid");
    }

    #[test]
    fn test_ekubo_insufficient_history_is_invalid() {
        let env = setup();
        let (asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);

        // the extension only has observations from inside the window
        extension.set_earliest_observation_time(START_TIME - MIN_TWAP_WINDOW + 1);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid, "insufficient history must be invalid");
        assert!(price.value == 0, "the window must not be silently shortened");

        // exactly one full window of history is enough
        extension.set_earliest_observation_time(START_TIME - MIN_TWAP_WINDOW);
        assert!(env.price_oracle.price(asset).is_valid, "a full window of history should be valid");
    }

    #[test]
    fn test_ekubo_decimals_normalisation() {
        let env = setup();
        // 6 decimal quote asset: the raw pool ratio has to be adjusted by both tokens' decimals
        let quote = deploy_asset_with_decimals(alice(), 6).contract_address;
        let quote_feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, quote, chainlink_config(quote_feed.contract_address, 3600, Zero::zero()));

        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        extension.set_earliest_observation_time(START_TIME - 2 * MIN_TWAP_WINDOW);
        // 2 raw quote units per raw base unit -> 2 * 10^18 / 10^6 = 2e12 whole quote per whole base
        extension.set_price_x128(MIN_TWAP_WINDOW, 2 * TWO_POW_128);
        add_ekubo(env, asset, ekubo_config(extension.contract_address, quote, MIN_TWAP_WINDOW));

        let (ratio, _) = env.oracle.twap(asset, MIN_TWAP_WINDOW);
        assert!(ratio == 2 * SCALE * pow_10(12), "decimals not applied to the pool ratio");
    }

    #[test]
    fn test_ekubo_spot_deviation_is_reported_not_enforced() {
        let env = setup();
        let (asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);

        // short window 20% above the configured window
        extension.set_price_x128(SPOT_TWAP_WINDOW, TWO_POW_128 * 12 / 10240);
        let (deviation, is_valid) = env.oracle.spot_deviation(asset);
        assert!(is_valid, "deviation should be computable");
        assert_approx(deviation, 20 * PERCENT, 1_000_000, "deviation incorrectly computed");

        // ... and the price stays valid: an invalidating rule here would be a griefing vector
        assert!(env.price_oracle.price(asset).is_valid, "spot deviation must not invalidate the price");
        assert!(env.price_oracle.price(asset).value == 3000 * SCALE / 1024, "the TWAP must still be reported");
    }

    #[test]
    #[should_panic(expected: "twap-window-too-short")]
    fn test_ekubo_window_floor_enforced() {
        let env = setup();
        let (eth, _) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        add_ekubo(env, asset, ekubo_config(extension.contract_address, eth, MIN_TWAP_WINDOW - 1));
    }

    // ------------------------------------------------------------------------------------------
    // Remaining read-path branches
    // ------------------------------------------------------------------------------------------

    #[test]
    fn test_ekubo_extension_without_observations_is_invalid() {
        let env = setup();
        let (asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);
        // distinct from insufficient history: the extension tracks nothing for this pair at all
        extension.set_earliest_observation_time(0);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid && price.value == 0, "an untracked pair must be invalid");
    }

    #[test]
    fn test_ekubo_zero_ratio_is_invalid() {
        let env = setup();
        let (asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);
        extension.set_price_x128(MIN_TWAP_WINDOW, 0);
        let (ratio, is_valid) = env.oracle.twap(asset, MIN_TWAP_WINDOW);
        assert!(!is_valid && ratio == 0, "a zero pool ratio must be invalid");
        assert!(!env.price_oracle.price(asset).is_valid, "a zero pool ratio must not price");
    }

    #[test]
    fn test_panicking_ekubo_extension_is_invalid_not_reverting() {
        let env = setup();
        let (asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);
        extension.set_should_panic(true);
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid && price.value == 0, "a panicking extension must be reported invalid");
        // the monitoring views degrade the same way rather than reverting on the caller
        let (_, twap_valid) = env.oracle.twap(asset, MIN_TWAP_WINDOW);
        assert!(!twap_valid, "twap must degrade too");
        let (_, deviation_valid) = env.oracle.spot_deviation(asset);
        assert!(!deviation_valid, "spot_deviation must degrade too");
    }

    #[test]
    fn test_scaled_zero_rate_is_invalid() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);
        wrapper.set_assets_per_share(0);
        let (rate, is_valid) = env.oracle.conversion_rate(asset);
        assert!(!is_valid && rate == 0, "a zero conversion rate must be out of bounds");
        assert!(!env.price_oracle.price(asset).is_valid, "a zero conversion rate must not price");
    }

    /// The cone is evaluated arithmetically from `ref_timestamp`, so a block timestamp behind the
    /// anchor must clamp `elapsed` to zero rather than underflow.
    #[test]
    fn test_rate_bounds_clamp_elapsed_behind_the_anchor() {
        let env = setup();
        let growth: u128 = 1_000_000_000_000;
        let (asset, wrapper) = setup_scaled(env, growth);

        start_cheat_block_timestamp_global(START_TIME - 1000);
        // no growth is allowed for negative elapsed: the anchor itself is the ceiling
        wrapper.set_assets_per_share(SCALE);
        assert!(env.price_oracle.price(asset).is_valid, "the anchor itself must stay valid");
        wrapper.set_assets_per_share(SCALE + 1);
        assert!(!env.price_oracle.price(asset).is_valid, "elapsed must clamp to zero, not run backwards");
    }

    #[test]
    fn test_spot_deviation_below_the_window_is_reported() {
        let env = setup();
        let (asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);
        // short window 20% *below* the configured window — the other side of the absolute difference
        extension.set_price_x128(SPOT_TWAP_WINDOW, TWO_POW_128 * 8 / 10240);
        let (deviation, is_valid) = env.oracle.spot_deviation(asset);
        assert!(is_valid, "deviation should be computable");
        assert_approx(deviation, 20 * PERCENT, 1_000_000, "deviation incorrectly computed");
    }

    #[test]
    fn test_spot_deviation_needs_both_windows() {
        let env = setup();
        let (asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);
        // the configured window resolves but the short one has no price recorded
        let (deviation, is_valid) = env.oracle.spot_deviation(asset);
        assert!(!is_valid && deviation == 0, "a missing spot leg must not be reported as a deviation");

        // and with too little history neither leg resolves
        extension.set_price_x128(SPOT_TWAP_WINDOW, TWO_POW_128 / 1024);
        extension.set_earliest_observation_time(START_TIME - 1);
        let (_, is_valid) = env.oracle.spot_deviation(asset);
        assert!(!is_valid, "insufficient history must not be reported as a deviation");
    }

    /// The monitoring views are route-kind specific and must report "not applicable" rather than
    /// silently answering for the wrong kind of route.
    #[test]
    fn test_monitoring_views_are_route_kind_gated() {
        let env = setup();
        let (chainlink_asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let (scaled_asset, _) = setup_scaled(env, 1_000_000_000_000);
        let (ekubo_asset, _) = setup_ekubo(env, MIN_TWAP_WINDOW);
        let unrouted = deploy_asset_with_decimals(alice(), 18).contract_address;

        for asset in array![chainlink_asset, ekubo_asset, unrouted] {
            let (rate, is_valid) = env.oracle.conversion_rate(asset);
            assert!(!is_valid && rate == 0, "conversion_rate must only answer for a Scaled route");
        }
        for asset in array![chainlink_asset, scaled_asset, unrouted] {
            let (ratio, is_valid) = env.oracle.twap(asset, MIN_TWAP_WINDOW);
            assert!(!is_valid && ratio == 0, "twap must only answer for an EkuboTwap route");
            let (deviation, is_valid) = env.oracle.spot_deviation(asset);
            assert!(!is_valid && deviation == 0, "spot_deviation must only answer for an EkuboTwap route");
        }
    }

    #[test]
    fn test_configuration_getters_round_trip() {
        let env = setup();
        assert!(env.oracle.pragma_oracle() == env.pragma.contract_address, "pragma oracle not exposed");
        assert!(env.oracle.route_timelock() == TIMELOCK, "timelock not exposed");
        assert!(env.oracle.upgrade_name() == 'Vesu Oracle V2', "upgrade name not exposed");

        let (ekubo_asset, extension) = setup_ekubo(env, MIN_TWAP_WINDOW);
        let config = env.oracle.ekubo_config(ekubo_asset);
        assert!(config.oracle_extension == extension.contract_address, "extension not stored");
        assert!(config.window == MIN_TWAP_WINDOW, "window not stored");
        // decimals are derived, not taken from the caller's input
        assert!(config.base_decimals == 18 && config.quote_decimals == 18, "decimals not derived");

        let pragma_asset = setup_pragma_asset(env, pragma_config_with(3600, 2));
        assert!(env.oracle.pragma_config(pragma_asset).pragma_key == PRAGMA_KEY, "pragma key not stored");

        let scaled = env.oracle.scaled_config(ekubo_asset);
        assert!(scaled.wrapper == Zero::zero(), "an unrelated kind's config must stay empty");
    }

    // ------------------------------------------------------------------------------------------
    // §11.9 Access control
    // ------------------------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: "route-already-set")]
    fn test_listing_is_only_for_unrouted_assets() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_listing_is_manager_only() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 100_000_000);
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.add_chainlink_asset(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_proposing_is_manager_only() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
    }

    #[test]
    #[should_panic(expected: "route-not-set")]
    fn test_proposing_requires_an_existing_route() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 100_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
    }

    #[test]
    #[should_panic(expected: "route-change-timelocked")]
    fn test_route_change_is_timelocked() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));

        let (is_pending, kind, eta) = env.oracle.pending_route_change(asset);
        assert!(is_pending, "pending change not recorded");
        assert!(kind == PriceRouteKind::Chainlink, "pending kind not recorded");
        assert!(eta == START_TIME + TIMELOCK, "eta not recorded");

        start_cheat_block_timestamp_global(START_TIME + TIMELOCK - 1);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
    }

    #[test]
    fn test_route_change_applies_after_the_timelock() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        assert!(env.price_oracle.price(asset).value == SCALE, "price not set up");

        let feed = deploy_feed(8, 200_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        // the live route is untouched until the change is applied
        assert!(env.price_oracle.price(asset).value == SCALE, "route changed before the timelock elapsed");

        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        assert!(env.price_oracle.price(asset).value == 2 * SCALE, "route not changed");
        let (is_pending, kind, eta) = env.oracle.pending_route_change(asset);
        assert!(!is_pending && kind == PriceRouteKind::None && eta == 0, "pending change not cleared");
        // the staged config is zeroed too, so raw storage cannot be misread as a live proposal
        assert!(env.oracle.chainlink_config(asset).feed != Zero::zero(), "the live config must survive");
    }

    #[test]
    #[should_panic(expected: "no-pending-route-change")]
    fn test_cancelled_route_change_cannot_be_applied() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.cancel_route_change(asset);

        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
    }

    #[test]
    fn test_scaled_route_change_re_anchors_on_application() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);
        let underlying = env.oracle.scaled_config(asset).base_asset;

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .propose_scaled_route(
                asset, scaled_config(underlying, asset, 2_000_000_000_000, 3 * SCALE.try_into().unwrap()),
            );

        // the rate accrues while the change sits in the timelock
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        wrapper.set_assets_per_share(1_100_000_000_000_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        let config = env.oracle.scaled_config(asset);
        assert!(config.ref_rate == 1_100_000_000_000_000_000, "anchor not refreshed on application");
        assert!(config.ref_timestamp == START_TIME + TIMELOCK, "anchor timestamp not refreshed");
        assert!(config.max_growth_per_second == 2_000_000_000_000, "new bounds not applied");
        assert!(env.price_oracle.price(asset).is_valid, "price should be valid after the change");
    }

    // ------------------------------------------------------------------------------------------
    // Decimals bounds: every `pow_10` argument on the price path is source reported, and `10^n`
    // overflows u256 well inside the range a `u8` or `u32` can carry. An overflow there is a panic
    // inside `price()`, which freezes borrow, repay, withdraw and liquidation on every pair listing
    // the asset — the failure the non-reverting design exists to prevent.
    // ------------------------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: "feed-decimals-out-of-range")]
    fn test_feed_decimals_out_of_range_rejected_at_config_time() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(100, 1);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
    }

    #[test]
    fn test_pragma_response_decimals_out_of_range_is_invalid_not_reverting() {
        // the one exponent no configuration-time check can bound: it arrives with the response
        start_cheat_block_timestamp_global(START_TIME);
        let pragma = deploy_contract("MockWideDecimalsPragma");
        let address = deploy_with_args(
            "OracleV2", array![owner().into(), manager().into(), pragma.into(), TIMELOCK.into()],
        );
        let oracle = IOracleV2Dispatcher { contract_address: address };
        let price_oracle = IOracleDispatcher { contract_address: address };

        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        cheat_caller_address(address, manager(), CheatSpan::TargetCalls(1));
        oracle
            .add_pragma_asset(
                asset,
                OracleConfig {
                    pragma_key: PRAGMA_KEY,
                    timeout: 3600,
                    number_of_sources: 2,
                    start_time_offset: 0,
                    time_window: 0,
                    aggregation_mode: AggregationMode::Median,
                },
            );

        let price = price_oracle.price(asset);
        assert!(!price.is_valid, "an out of range decimals must be invalid");
        assert!(price.value == 0, "an out of range decimals must not report a value");
    }

    // ------------------------------------------------------------------------------------------
    // Anchor vs ceiling: `validated_scaled_config` checks `max_rate >= ref_rate` at proposal time,
    // but the anchor is re-taken on application. A rate that crosses `max_rate` during the timelock
    // would otherwise install `upper = max_rate < ref_rate` and invalidate the asset on every read.
    // ------------------------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: "max-rate-below-anchor")]
    fn test_apply_rejects_an_anchor_above_the_ceiling() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);
        let underlying = env.oracle.scaled_config(asset).base_asset;

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .propose_scaled_route(
                asset, scaled_config(underlying, asset, 1_000_000_000_000, 1_010_000_000_000_000_000),
            );

        // the rate crosses the proposed ceiling while the change sits in the timelock
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        wrapper.set_assets_per_share(1_050_000_000_000_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
    }

    #[test]
    #[should_panic(expected: "max-rate-below-anchor")]
    fn test_reanchor_rejects_an_anchor_above_the_ceiling() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);

        wrapper.set_assets_per_share(3 * SCALE);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(asset);
    }

    #[test]
    #[should_panic(expected: "invalid-zero-max-growth")]
    fn test_zero_max_growth_is_rejected() {
        // zero is the struct's unset value and pins the ceiling at `ref_rate`, so the first wei of
        // yield accrual would invalidate the route permanently
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        add_scaled(
            env,
            wrapper.contract_address,
            scaled_config(underlying, wrapper.contract_address, 0, 2 * SCALE.try_into().unwrap()),
        );
    }

    #[test]
    #[should_panic(expected: "wrapper-must-be-the-asset")]
    fn test_scaled_route_requires_the_wrapper_to_be_the_asset() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 200_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        add_scaled(
            env,
            asset,
            scaled_config(underlying, wrapper.contract_address, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
    }

    /// A bad `oracle_extension` must not reach the read path: `safe_call` degrades a panicking or
    /// malformed source to an invalid price, but an address with no class deployed fails the whole
    /// transaction, so it has to be kept out of a route at write time. Chainlink and Scaled routes
    /// read their source during validation as a side effect of caching decimals; the Ekubo extension
    /// has to be probed explicitly, because its cached decimals come from the tokens instead.
    ///
    /// Only the recoverable half is asserted here — a deployed contract without the entrypoint. The
    /// undeployed case is out of scope for an in-test assertion for the same reason it is out of
    /// scope for the read path (§3.4): it is not a Cairo panic and cannot be caught.
    #[test]
    #[should_panic]
    fn test_ekubo_extension_is_probed_at_config_time() {
        let env = setup();
        let (eth, _) = setup_usd_asset(env, 18, 300_000_000_000);
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        // a real contract that does not answer `get_earliest_observation_time`
        let not_an_extension = deploy_contract("MockMalformedFeed");
        add_ekubo(env, asset, ekubo_config(not_an_extension, eth, MIN_TWAP_WINDOW));
    }

    /// The 2^128 ratio is normalised to SCALE and adjusted for both tokens' decimals in one
    /// full-width mul_div. Truncating to SCALE first would cap the relative precision at
    /// `1 / (price * 10^quote_decimals / 10^base_decimals)` — a third of a percent here.
    #[test]
    fn test_ekubo_precision_survives_the_decimals_adjustment() {
        let env = setup();
        let quote = deploy_asset_with_decimals(alice(), 6).contract_address;
        let quote_feed = deploy_feed(8, 100_000_000);
        add_chainlink(env, quote, chainlink_config(quote_feed.contract_address, 3600, Zero::zero()));

        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        extension.set_earliest_observation_time(START_TIME - 2 * MIN_TWAP_WINDOW);
        // a raw ratio whose SCALE representation is ~123.45, i.e. 0.00012345 quote per base
        extension.set_price_x128(MIN_TWAP_WINDOW, 42007858196389853314553);

        add_ekubo(env, asset, ekubo_config(extension.contract_address, quote, MIN_TWAP_WINDOW));

        let (ratio, is_valid) = env.oracle.twap(asset, MIN_TWAP_WINDOW);
        assert!(is_valid, "TWAP should be valid");
        // truncating to SCALE first would give 123_000_000_000_000, 0.36% low
        assert!(ratio == 123_449_999_999_999, "precision lost in the decimals adjustment: {}", ratio);
    }

    // ------------------------------------------------------------------------------------------
    // Delisting
    // ------------------------------------------------------------------------------------------

    #[test]
    fn test_deactivation_is_timelocked_and_prices_zero() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        assert!(env.price_oracle.price(asset).is_valid, "price not set up");

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_none_route(asset);
        let (is_pending, kind, eta) = env.oracle.pending_route_change(asset);
        assert!(is_pending, "a deactivation must register as pending even though its kind is None");
        assert!(kind == PriceRouteKind::None && eta == START_TIME + TIMELOCK, "deactivation not staged");
        assert!(env.price_oracle.price(asset).is_valid, "the route must survive the timelock");

        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        assert!(env.oracle.route_kind(asset) == PriceRouteKind::None, "route not cleared");
        let price = env.price_oracle.price(asset);
        assert!(!price.is_valid && price.value == 0, "a deactivated asset must price zero and invalid");
        // and it is no longer usable as a quote leg
        assert!(!env.oracle.price_terminal(asset).is_valid, "a deactivated asset is not a terminal route");
        // its typed config survives, so reactivating is a route change and not a fresh listing
        assert!(env.oracle.chainlink_config(asset).feed.is_non_zero(), "the config must survive deactivation");
    }

    /// A deactivated asset has no live route, so reactivating it is a listing again. The route it
    /// comes back with is instant, exactly as a first listing is — deactivation is a deliberate
    /// freeze, not a quarantine.
    #[test]
    fn test_deactivated_asset_can_be_reactivated() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_none_route(asset);
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
        assert!(!env.price_oracle.price(asset).is_valid, "asset not deactivated");

        let feed = deploy_feed(8, 200_000_000);
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        assert!(env.price_oracle.price(asset).value == 2 * SCALE, "asset not reactivated");
    }

    #[test]
    #[should_panic(expected: "route-not-set")]
    fn test_deactivating_twice_is_rejected() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_none_route(asset);
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_none_route(asset);
    }

    #[test]
    fn test_cancelling_clears_the_staged_config() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.cancel_route_change(asset);

        let (is_pending, kind, eta) = env.oracle.pending_route_change(asset);
        assert!(!is_pending && kind == PriceRouteKind::None && eta == 0, "cancellation not recorded");
        // the live route is untouched
        assert!(env.price_oracle.price(asset).value == SCALE, "cancelling must not touch the live route");
    }

    #[test]
    #[should_panic]
    fn test_constructor_rejects_a_zero_pragma_oracle() {
        deploy_with_args("OracleV2", array![owner().into(), manager().into(), Zero::zero(), TIMELOCK.into()]);
    }

    #[test]
    fn test_ekubo_route_change_applies_after_the_timelock() {
        let env = setup();
        let (asset, _) = setup_ekubo(env, MIN_TWAP_WINDOW);
        let quote = env.oracle.ekubo_config(asset).quote_asset;

        let replacement = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        replacement.set_earliest_observation_time(START_TIME - 4 * MIN_TWAP_WINDOW);
        replacement.set_price_x128(2 * MIN_TWAP_WINDOW, TWO_POW_128 / 512);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_ekubo_route(asset, ekubo_config(replacement.contract_address, quote, 2 * MIN_TWAP_WINDOW));
        assert!(env.price_oracle.price(asset).value == 3000 * SCALE / 1024, "route changed before the timelock");

        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        let config = env.oracle.ekubo_config(asset);
        assert!(config.oracle_extension == replacement.contract_address, "extension not repointed");
        assert!(config.window == 2 * MIN_TWAP_WINDOW, "window not applied");
        assert!(env.price_oracle.price(asset).value == 3000 * SCALE / 512, "new route not live");
    }

    #[test]
    fn test_pragma_route_change_applies_after_the_timelock() {
        let env = setup();
        let asset = setup_pragma_asset(env, pragma_config_with(3600, 2));
        assert!(env.price_oracle.price(asset).is_valid, "price not set up");

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_pragma_route(asset, pragma_config_with(3600, 9));
        assert!(env.price_oracle.price(asset).is_valid, "route changed before the timelock");

        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        assert!(env.oracle.pragma_config(asset).number_of_sources == 9, "new config not applied");
        // the mock aggregates 2 sources, so the tightened requirement now fails closed
        assert!(!env.price_oracle.price(asset).is_valid, "the tightened source count must take effect");
    }

    /// A route change may also change the *kind*. The replaced kind's config is left behind in its
    /// own map, which is harmless only because `routes` is what dispatches every read.
    #[test]
    fn test_route_change_across_kinds() {
        let env = setup();
        let asset = setup_pragma_asset(env, pragma_config_with(3600, 2));
        assert!(env.oracle.route_kind(asset) == PriceRouteKind::Pragma, "route not set up");

        let feed = deploy_feed(8, 500_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        assert!(env.oracle.route_kind(asset) == PriceRouteKind::Chainlink, "kind not switched");
        assert!(env.price_oracle.price(asset).value == 5 * SCALE, "the new kind is not the one being read");
        // the old config is still in storage and is simply never consulted again
        assert!(env.oracle.pragma_config(asset).pragma_key == PRAGMA_KEY, "the replaced config is left in place");
    }

    #[test]
    fn test_reproposing_replaces_the_pending_change() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let first = deploy_feed(8, 200_000_000);
        let second = deploy_feed(8, 700_000_000);

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(first.contract_address, 3600, Zero::zero()));

        // a second proposal supersedes the first and restarts the clock
        start_cheat_block_timestamp_global(START_TIME + 100);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(second.contract_address, 3600, Zero::zero()));
        let (is_pending, _, eta) = env.oracle.pending_route_change(asset);
        assert!(is_pending && eta == START_TIME + 100 + TIMELOCK, "the eta must restart with the new proposal");

        start_cheat_block_timestamp_global(START_TIME + 100 + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
        assert!(env.price_oracle.price(asset).value == 7 * SCALE, "the superseding proposal must be the one applied");
    }

    #[test]
    #[should_panic(expected: "not-a-scaled-route")]
    fn test_reanchor_rejects_a_non_scaled_route() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(asset);
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_cancelling_is_manager_only() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.cancel_route_change(asset);
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_applying_is_manager_only() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_nominating_a_manager_is_manager_only() {
        let env = setup();
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.nominate_manager(alice());
    }

    #[test]
    #[should_panic(expected: "caller-not-new-manager")]
    fn test_only_the_nominee_can_accept_the_manager_role() {
        let env = setup();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.nominate_manager(alice());
        cheat_caller_address(env.oracle.contract_address, contract_address_const::<'bob'>(), CheatSpan::TargetCalls(1));
        env.oracle.accept_manager_ownership();
    }

    // ------------------------------------------------------------------------------------------
    // Upgrades. Owner gated, and guarded by `upgrade_name` so a class for a different contract
    // cannot be installed by mistake.
    // ------------------------------------------------------------------------------------------

    #[test]
    #[should_panic(expected: 'Caller is not the owner')]
    fn test_upgrade_is_owner_only() {
        let env = setup();
        let new_class = *declare("MockOracleV2Upgrade").unwrap().contract_class().class_hash;
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.upgrade(new_class, Option::None);
    }

    #[test]
    fn test_upgrade_replaces_the_class() {
        let env = setup();
        let new_class = *declare("MockOracleV2Upgrade").unwrap().contract_class().class_hash;
        cheat_caller_address(env.oracle.contract_address, owner(), CheatSpan::TargetCalls(1));
        env.oracle.upgrade(new_class, Option::None);
        let tag = IMockOracleV2UpgradeDispatcher { contract_address: env.oracle.contract_address }.tag();
        assert!(tag == 'MockOracleV2Upgrade', "the class was not replaced");
    }

    #[test]
    #[should_panic(expected: ('invalid upgrade name',))]
    fn test_upgrade_rejects_a_class_for_another_contract() {
        let env = setup();
        let wrong_class = *declare("MockPoolUpgrade").unwrap().contract_class().class_hash;
        cheat_caller_address(env.oracle.contract_address, owner(), CheatSpan::TargetCalls(1));
        env.oracle.upgrade(wrong_class, Option::None);
    }

    #[test]
    fn test_upgrade_runs_the_eic_before_replacing_the_class() {
        let env = setup();
        assert!(env.oracle.route_timelock() == TIMELOCK, "timelock not set up");
        let new_class = *declare("MockOracleV2Upgrade").unwrap().contract_class().class_hash;
        let eic_class = *declare("MockOracleV2EIC").unwrap().contract_class().class_hash;

        cheat_caller_address(env.oracle.contract_address, owner(), CheatSpan::TargetCalls(1));
        env.oracle.upgrade(new_class, Some((eic_class, array![172800].span())));
        // read through the pre-upgrade ABI, which the mock no longer implements, so go via storage
        let timelock = load(env.oracle.contract_address, selector!("route_timelock"), 1);
        assert!(*timelock[0] == 172800, "the eic did not migrate the timelock");
    }

    // ------------------------------------------------------------------------------------------
    // Events. §9's depeg monitoring and automated pausing is driven entirely off these, and the
    // oracle cannot emit from the read path at all (§2), so everything the monitor needs has to be
    // on a write. These tests pin that contract: what is staged, what went live, and what changed.
    // ------------------------------------------------------------------------------------------

    #[test]
    fn test_listing_emits_the_route_and_its_full_config() {
        let env = setup();
        let asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 100_000_000);
        let mut spy = spy_events();
        add_chainlink(env, asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));

        let config = ChainlinkConfig {
            feed: feed.contract_address, feed_decimals: 8, max_staleness: 3600, quote_asset: Zero::zero(),
        };
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetChainlinkConfig(
                            OracleV2::SetChainlinkConfig { asset, pending: false, config },
                        ),
                    ),
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetRoute(OracleV2::SetRoute { asset, kind: PriceRouteKind::Chainlink }),
                    ),
                ],
            );
    }

    /// The staged config is emitted at proposal time, not only when it lands, so the parameters of a
    /// pending change are reviewable for the whole delay (§7).
    #[test]
    fn test_proposal_emits_the_staged_config_and_the_eta() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);

        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 7200, Zero::zero()));

        let staged = ChainlinkConfig {
            feed: feed.contract_address, feed_decimals: 8, max_staleness: 7200, quote_asset: Zero::zero(),
        };
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::ProposeRouteChange(
                            OracleV2::ProposeRouteChange {
                                asset, kind: PriceRouteKind::Chainlink, eta: START_TIME + TIMELOCK,
                            },
                        ),
                    ),
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetChainlinkConfig(
                            OracleV2::SetChainlinkConfig { asset, pending: true, config: staged },
                        ),
                    ),
                ],
            );
        // and the same config is re-emitted as live when it is applied
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetChainlinkConfig(
                            OracleV2::SetChainlinkConfig { asset, pending: false, config: staged },
                        ),
                    ),
                ],
            );
    }

    #[test]
    fn test_cancellation_emits_what_was_cancelled() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        let feed = deploy_feed(8, 200_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_chainlink_route(asset, chainlink_config(feed.contract_address, 3600, Zero::zero()));

        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.cancel_route_change(asset);
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::CancelRouteChange(
                            OracleV2::CancelRouteChange {
                                asset, kind: PriceRouteKind::Chainlink, eta: START_TIME + TIMELOCK,
                            },
                        ),
                    ),
                ],
            );
    }

    #[test]
    fn test_deactivation_emits_a_none_route() {
        let env = setup();
        let (asset, _) = setup_usd_asset(env, 18, 100_000_000);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.propose_none_route(asset);
        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);

        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetRoute(OracleV2::SetRoute { asset, kind: PriceRouteKind::None }),
                    ),
                ],
            );
    }

    /// §9 watches for any decrease in the wrapper rate, which needs the previous anchor alongside the
    /// new one — a single `ref_rate` would force the monitor to hold its own history.
    #[test]
    fn test_anchor_events_carry_the_previous_rate() {
        let env = setup();
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        let asset = wrapper.contract_address;

        let mut spy = spy_events();
        add_scaled(env, asset, scaled_config(underlying, asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()));
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetAnchor(
                            OracleV2::SetAnchor {
                                asset,
                                previous_ref_rate: 0,
                                ref_rate: SCALE.try_into().unwrap(),
                                ref_timestamp: START_TIME,
                            },
                        ),
                    ),
                ],
            );

        start_cheat_block_timestamp_global(START_TIME + 1000);
        wrapper.set_assets_per_share(1_000_000_000_000_100_000);
        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(asset);
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetAnchor(
                            OracleV2::SetAnchor {
                                asset,
                                previous_ref_rate: SCALE.try_into().unwrap(),
                                ref_rate: 1_000_000_000_000_100_000,
                                ref_timestamp: START_TIME + 1000,
                            },
                        ),
                    ),
                ],
            );
    }

    #[test]
    fn test_every_route_kind_emits_its_typed_config() {
        let env = setup();

        // Scaled
        let (underlying, _) = setup_usd_asset(env, 18, 100_000_000);
        let wrapper = deploy_wrapper(underlying, 18, SCALE);
        let scaled_asset = wrapper.contract_address;
        let mut spy = spy_events();
        add_scaled(
            env,
            scaled_asset,
            scaled_config(underlying, scaled_asset, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()),
        );
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetScaledConfig(
                            OracleV2::SetScaledConfig {
                                asset: scaled_asset, pending: false, config: env.oracle.scaled_config(scaled_asset),
                            },
                        ),
                    ),
                ],
            );

        // EkuboTwap
        let ekubo_asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let extension = IMockEkuboOracleDispatcher { contract_address: deploy_contract("MockEkuboOracle") };
        let mut spy = spy_events();
        add_ekubo(env, ekubo_asset, ekubo_config(extension.contract_address, underlying, MIN_TWAP_WINDOW));
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetEkuboConfig(
                            OracleV2::SetEkuboConfig {
                                asset: ekubo_asset, pending: false, config: env.oracle.ekubo_config(ekubo_asset),
                            },
                        ),
                    ),
                ],
            );

        // Pragma
        let pragma_asset = deploy_asset_with_decimals(alice(), 18).contract_address;
        let config = pragma_config_with(3600, 2);
        let mut spy = spy_events();
        add_pragma(env, pragma_asset, config);
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetPragmaConfig(
                            OracleV2::SetPragmaConfig { asset: pragma_asset, pending: false, config },
                        ),
                    ),
                ],
            );
    }

    /// A `Scaled` route is the one kind whose applied config differs from the staged one: the anchor
    /// is re-taken from the wrapper on application (§6.3). Both versions must be on the wire, or a
    /// monitor reconciling the staged proposal against what landed would flag a false mismatch.
    #[test]
    fn test_scaled_apply_emits_the_re_anchored_config_not_the_staged_one() {
        let env = setup();
        let (asset, wrapper) = setup_scaled(env, 1_000_000_000_000);
        let underlying = env.oracle.scaled_config(asset).base_asset;

        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .propose_scaled_route(
                asset, scaled_config(underlying, asset, 2_000_000_000_000, 3 * SCALE.try_into().unwrap()),
            );
        let staged = ScaledConfig {
            base_asset: underlying,
            wrapper: asset,
            share_decimals: 18,
            underlying_decimals: 18,
            ref_rate: SCALE.try_into().unwrap(),
            ref_timestamp: START_TIME,
            max_growth_per_second: 2_000_000_000_000,
            min_rate_ratio: 990_000_000_000_000_000,
            max_rate: 3 * SCALE.try_into().unwrap(),
        };
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetScaledConfig(
                            OracleV2::SetScaledConfig { asset, pending: true, config: staged },
                        ),
                    ),
                ],
            );

        start_cheat_block_timestamp_global(START_TIME + TIMELOCK);
        wrapper.set_assets_per_share(1_100_000_000_000_000_000);
        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(asset);

        let applied = ScaledConfig {
            ref_rate: 1_100_000_000_000_000_000, ref_timestamp: START_TIME + TIMELOCK, ..staged,
        };
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetScaledConfig(
                            OracleV2::SetScaledConfig { asset, pending: false, config: applied },
                        ),
                    ),
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetAnchor(
                            OracleV2::SetAnchor {
                                asset,
                                previous_ref_rate: SCALE.try_into().unwrap(),
                                ref_rate: 1_100_000_000_000_000_000,
                                ref_timestamp: START_TIME + TIMELOCK,
                            },
                        ),
                    ),
                ],
            );
    }

    #[test]
    fn test_manager_transfer_emits_both_steps() {
        let env = setup();
        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.nominate_manager(alice());
        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.accept_manager_ownership();

        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::NominateManager(OracleV2::NominateManager { pending_manager: alice() }),
                    ),
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::SetManager(
                            OracleV2::SetManager { manager: alice(), previous_manager: manager() },
                        ),
                    ),
                ],
            );
    }

    #[test]
    fn test_upgrade_emits_the_eic_it_ran() {
        let env = setup();
        let new_class = *declare("MockOracleV2Upgrade").unwrap().contract_class().class_hash;
        let eic_class = *declare("MockOracleV2EIC").unwrap().contract_class().class_hash;

        let mut spy = spy_events();
        cheat_caller_address(env.oracle.contract_address, owner(), CheatSpan::TargetCalls(1));
        env.oracle.upgrade(new_class, Some((eic_class, array![172800].span())));
        spy
            .assert_emitted(
                @array![
                    (
                        env.oracle.contract_address,
                        OracleV2::Event::ContractUpgraded(
                            OracleV2::ContractUpgraded {
                                new_implementation: new_class, eic_implementation: Some(eic_class),
                            },
                        ),
                    ),
                ],
            );
    }

    // ------------------------------------------------------------------------------------------
    // Pair invariance through the real `Pool` contract
    //
    // The fork tests assert this property on oracle outputs, reproducing the pool's solvency formula
    // in the test. That is necessary there — no V2 pool exists on mainnet to call — but it means those
    // tests rely on a *copy* of `common::calculate_collateral_and_debt_value`, and skip share
    // accounting and interest accrual entirely.
    //
    // These run the same property through the real `Pool`: a real position, real collateral shares,
    // real `nominal_debt` and rate accumulator, and the pool's own `check_collateralization`. The only
    // mocks are the price *sources* and the tokens, which is the right place for them — the property is
    // about the oracle's composition structure, not about which ERC-20 is involved.
    // ------------------------------------------------------------------------------------------

    /// Pool with a `Scaled` wrapper as collateral and its own underlying as debt, plus a funded
    /// position. Returns the pool, the wrapper, the underlying and the underlying's feed.
    fn setup_wrapper_pool(
        env: Env, max_ltv: u256,
    ) -> (
        IPoolDispatcher, ContractAddress, ContractAddress, IMockChainlinkFeedDispatcher, IMockWrapperTokenDispatcher,
    ) {
        let underlying = deploy_asset_with_decimals(alice(), 18).contract_address;
        let feed = deploy_feed(8, 100_000_000); // the underlying at $1 to start
        add_chainlink(env, underlying, chainlink_config(feed.contract_address, 3600, Zero::zero()));
        // an ERC-20 that is also ERC-4626 shaped, so the pool can hold it and the router can price it
        let wrapper = deploy_with_args(
            "MockWrapperToken",
            array![
                underlying.into(),
                18,
                1_200_000_000_000_000_000, // rate 1.2
                0,
                (100 * SCALE).low.into(),
                (100 * SCALE).high.into(),
                alice().into(),
            ],
        );
        let wrapper_mock = IMockWrapperTokenDispatcher { contract_address: wrapper };
        add_scaled(env, wrapper, scaled_config(underlying, wrapper, 1_000_000_000_000, 2 * SCALE.try_into().unwrap()));

        let curator = contract_address_const::<'curator'>();
        let pool = IPoolDispatcher {
            contract_address: deploy_with_args(
                "Pool", array!['PoolName', owner().into(), curator.into(), env.oracle.contract_address.into()],
            ),
        };

        let collateral_token = IERC20Dispatcher { contract_address: wrapper };
        let debt_token = IERC20Dispatcher { contract_address: underlying };

        // `add_asset` takes an INFLATION_FEE deposit from the curator, so the curator needs a balance
        // of both assets, not just of the one it supplies
        cheat_caller_address(underlying, alice(), CheatSpan::TargetCalls(1));
        debt_token.transfer(curator, 10 * SCALE);
        cheat_caller_address(wrapper, alice(), CheatSpan::TargetCalls(1));
        collateral_token.transfer(curator, 10 * SCALE);
        for account in array![alice(), curator] {
            cheat_caller_address(underlying, account, CheatSpan::TargetCalls(1));
            debt_token.approve(pool.contract_address, 100 * SCALE);
            cheat_caller_address(wrapper, account, CheatSpan::TargetCalls(1));
            collateral_token.approve(pool.contract_address, 100 * SCALE);
        }

        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool.add_asset(asset_params(wrapper), interest_rate_config());
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool.add_asset(asset_params(underlying), interest_rate_config());
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool
            .set_pair_config(
                wrapper,
                underlying,
                PairConfig { max_ltv: max_ltv.try_into().unwrap(), liquidation_factor: 0, debt_cap: 0 },
            );
        (pool, wrapper, underlying, feed, wrapper_mock)
    }

    /// The property, through the real pool: a wrapper-collateral / underlying-debt position is solvent
    /// or not according to the conversion rate alone. Sweeping the underlying's USD price over five
    /// orders of magnitude must not move the verdict, the collateral-to-debt value ratio, or anything
    /// else `check_collateralization` reports beyond a proportional rescaling of both values.
    #[test]
    fn test_pool_wrapper_position_solvency_ignores_the_underlying_price() {
        let env = setup();
        let max_ltv = 80 * PERCENT;
        let (pool, wrapper, underlying, feed, _) = setup_wrapper_pool(env, max_ltv);

        // the curator supplies the debt asset so there is something to borrow
        let curator = contract_address_const::<'curator'>();
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: underlying,
                    debt_asset: wrapper,
                    user: curator,
                    collateral: Amount { denomination: AmountDenomination::Assets, value: (5 * SCALE).into() },
                    debt: Default::default(),
                },
            );

        // alice posts 1 wrapper unit and borrows 0.9 underlying — inside 80% of a 1.2 rate
        cheat_caller_address(pool.contract_address, alice(), CheatSpan::TargetCalls(1));
        pool
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: wrapper,
                    debt_asset: underlying,
                    user: alice(),
                    collateral: Amount { denomination: AmountDenomination::Assets, value: SCALE.into() },
                    debt: Amount { denomination: AmountDenomination::Assets, value: (9 * SCALE / 10).into() },
                },
            );

        let (solvent, first_collateral_value, first_debt_value) = pool
            .check_collateralization(wrapper, underlying, alice());
        assert!(solvent, "the position must start out solvent");
        let reference_ltv = first_debt_value * SCALE / first_collateral_value;

        // sweep the shared leg. Both values rescale, the ratio does not.
        for answer in array![1_u128, 1_000_000, 100_000_000, 10_000_000_000, 1_000_000_000_000] {
            feed.set_answer(answer);
            let (solvent, collateral_value, debt_value) = pool.check_collateralization(wrapper, underlying, alice());
            assert!(solvent, "solvency must not depend on the underlying's USD price (answer {})", answer);
            assert!(collateral_value != 0 && debt_value != 0, "both legs must still value");
            let ltv = debt_value * SCALE / collateral_value;
            assert_approx(ltv, reference_ltv, 1_000_000_000, "the LTV moved with the underlying's price");

            // and the pool's own numbers are exactly the formula the fork tests mirror
            let collateral_price = pool.price(wrapper).value;
            let debt_price = pool.price(underlying).value;
            assert!(
                collateral_value == u256_mul_div(SCALE, collateral_price, SCALE, Rounding::Floor),
                "collateral value is not floor(collateral x price / scale)",
            );
            // the debt side ceils, and carries accrued interest, so it is bounded rather than exact
            assert!(
                debt_value >= u256_mul_div(9 * SCALE / 10, debt_price, SCALE, Rounding::Ceil),
                "debt value is below the principal it was opened with",
            );
            assert!(solvent == is_collateralized(collateral_value, debt_value, max_ltv), "verdict formula mismatch");
        }
    }

    /// The converse, through the real pool: the conversion rate is what moves solvency. A fall in the
    /// wrapper's rate liquidates the same position that no amount of underlying-price movement could.
    #[test]
    fn test_pool_wrapper_position_solvency_tracks_the_conversion_rate() {
        let env = setup();
        let max_ltv = 80 * PERCENT;
        let (pool, wrapper, underlying, _, wrapper_mock) = setup_wrapper_pool(env, max_ltv);

        let curator = contract_address_const::<'curator'>();
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: underlying,
                    debt_asset: wrapper,
                    user: curator,
                    collateral: Amount { denomination: AmountDenomination::Assets, value: (5 * SCALE).into() },
                    debt: Default::default(),
                },
            );
        cheat_caller_address(pool.contract_address, alice(), CheatSpan::TargetCalls(1));
        pool
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: wrapper,
                    debt_asset: underlying,
                    user: alice(),
                    collateral: Amount { denomination: AmountDenomination::Assets, value: SCALE.into() },
                    debt: Amount { denomination: AmountDenomination::Assets, value: (9 * SCALE / 10).into() },
                },
            );
        let (solvent, _, _) = pool.check_collateralization(wrapper, underlying, alice());
        assert!(solvent, "the position must start out solvent");

        // 0.9 of debt at 80% LTV needs a rate of at least 0.9 / 0.8 = 1.125, so 1.15 still holds
        wrapper_mock.set_assets_per_share(1_150_000_000_000_000_000);
        let (solvent, _, _) = pool.check_collateralization(wrapper, underlying, alice());
        assert!(solvent, "a rate of 1.15 still covers 0.9 of debt at 80% LTV");

        // and 1.10 is below the threshold, so the same position is now liquidatable
        wrapper_mock.set_assets_per_share(1_100_000_000_000_000_000);
        let (solvent, _, _) = pool.check_collateralization(wrapper, underlying, alice());
        assert!(!solvent, "a rate of 1.10 must not, so the conversion rate is what determines solvency");
    }

    #[test]
    fn test_manager_two_step_transfer() {
        let env = setup();
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.nominate_manager(alice());
        assert!(env.oracle.pending_manager() == alice(), "nomination not recorded");

        cheat_caller_address(env.oracle.contract_address, alice(), CheatSpan::TargetCalls(1));
        env.oracle.accept_manager_ownership();
        assert!(env.oracle.manager() == alice(), "manager not transferred");
        assert!(env.oracle.pending_manager() == Zero::zero(), "pending manager not cleared");
    }
}
