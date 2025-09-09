#[cfg(test)]
mod TestPragmaOracle {
    use core::num::traits::{Bounded, Zero};
    use snforge_std::{CheatSpan, cheat_caller_address, map_entry_address, start_cheat_block_timestamp_global, store};
    use starknet::{ContractAddress, get_block_timestamp};
    use vesu::common::is_collateralized;
    use vesu::data_model::{AssetParams, PairConfig, PairParams};
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::oracle::{
        IOracleDispatcher, IOracleDispatcherTrait, IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait, OracleConfig,
    };
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::test::mock_oracle::{
        IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait, IMockPragmaSummaryDispatcher,
        IMockPragmaSummaryDispatcherTrait,
    };
    use vesu::test::setup_v2::{COLL_PRAGMA_KEY, DEBT_PRAGMA_KEY, Env, TestConfig, setup, setup_env};
    use vesu::units::{PERCENT, SCALE};
    use vesu::vendor::pragma::AggregationMode;


    fn create_custom_pool(
        owner: ContractAddress,
        curator: ContractAddress,
        pool: IPoolDispatcher,
        oracle: IPragmaOracleDispatcher,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        timeout: u64,
        number_of_sources: u32,
    ) {
        let interest_rate_config = InterestRateConfig {
            min_target_utilization: 75_000,
            max_target_utilization: 99_999,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        };

        let collateral_asset_params = AssetParams {
            asset: collateral_asset,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: true,
            fee_rate: 0,
        };
        let debt_asset_params = AssetParams {
            asset: debt_asset,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        let collateral_oracle_config = OracleConfig {
            pragma_key: COLL_PRAGMA_KEY,
            timeout: timeout,
            number_of_sources: number_of_sources,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median,
        };
        let debt_oracle_config = OracleConfig {
            pragma_key: DEBT_PRAGMA_KEY,
            timeout: timeout,
            number_of_sources: number_of_sources,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median,
        };

        let pair_params_0 = PairParams {
            collateral_asset_index: 0,
            debt_asset_index: 1,
            max_ltv: (80 * PERCENT).try_into().unwrap(),
            liquidation_factor: 0,
            debt_cap: 0,
        };

        let pair_params_1 = PairParams {
            collateral_asset_index: 1,
            debt_asset_index: 0,
            max_ltv: (80 * PERCENT).try_into().unwrap(),
            liquidation_factor: 0,
            debt_cap: 0,
        };

        // Add assets
        cheat_caller_address(oracle.contract_address, curator, CheatSpan::TargetCalls(1));
        oracle.add_asset(asset: collateral_asset_params.asset, oracle_config: collateral_oracle_config);
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool.add_asset(params: collateral_asset_params, interest_rate_config: interest_rate_config);

        cheat_caller_address(oracle.contract_address, curator, CheatSpan::TargetCalls(1));
        oracle.add_asset(asset: debt_asset_params.asset, oracle_config: debt_oracle_config);
        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool.add_asset(params: debt_asset_params, interest_rate_config: interest_rate_config);

        let collateral_asset = collateral_asset_params.asset;
        let debt_asset = debt_asset_params.asset;

        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool
            .set_pair_config(
                collateral_asset,
                debt_asset,
                PairConfig {
                    max_ltv: pair_params_0.max_ltv,
                    liquidation_factor: pair_params_0.liquidation_factor,
                    debt_cap: pair_params_0.debt_cap,
                },
            );

        let collateral_asset = debt_asset_params.asset;
        let debt_asset = collateral_asset_params.asset;

        cheat_caller_address(pool.contract_address, curator, CheatSpan::TargetCalls(1));
        pool
            .set_pair_config(
                collateral_asset,
                debt_asset,
                PairConfig {
                    max_ltv: pair_params_1.max_ltv,
                    liquidation_factor: pair_params_1.liquidation_factor,
                    debt_cap: pair_params_1.debt_cap,
                },
            );
    }

    #[test]
    fn test_get_default_price() {
        let (_, oracle, config, _, _) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };
        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);
        let debt_asset_price = price_oracle.price(debt_asset.contract_address);

        assert!(collateral_asset_price.value == SCALE, "Collateral asset price not correctly set");
        assert!(debt_asset_price.value == SCALE, "Debt asset price not correctly set");
        assert!(collateral_asset_price.is_valid, "Debt asset validity should be true");
        assert!(debt_asset_price.is_valid, "Debt asset validity should be true");
    }

    #[test]
    #[should_panic(expected: "invalid-pragma-key")]
    fn test_invalid_pragma_key() {
        let (_, oracle, _, _, _) = setup();
        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };

        price_oracle.price(Zero::zero());
    }

    #[test]
    fn test_get_price_high() {
        let (_, oracle, config, _, _) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        let pragma_oracle = IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() };
        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };

        let max: u128 = Bounded::<u128>::MAX;
        // set collateral asset price
        pragma_oracle.set_price(COLL_PRAGMA_KEY, max);
        // set debt asset price
        pragma_oracle.set_price(DEBT_PRAGMA_KEY, max);

        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);
        let debt_asset_price = price_oracle.price(debt_asset.contract_address);

        assert!(collateral_asset_price.value == max.into(), "Collateral asset price not correctly set");
        assert!(debt_asset_price.value == max.into(), "Debt asset price not correctly set");
        assert!(collateral_asset_price.is_valid, "Debt asset validity should be true");
        assert!(debt_asset_price.is_valid, "Debt asset validity should be true");

        let max_pair_LTV_ratio = 10 * SCALE;
        let check_collat = is_collateralized(collateral_asset_price.value, debt_asset_price.value, max_pair_LTV_ratio);
        assert!(check_collat, "Collateralization check failed");
    }

    #[test]
    fn test_is_valid_timeout() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        let timeout = 10;

        create_custom_pool(
            users.owner,
            users.curator,
            pool,
            oracle,
            collateral_asset.contract_address,
            debt_asset.contract_address,
            timeout,
            2,
        );

        let pragma_oracle = IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() };
        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };
        pragma_oracle.set_last_updated_timestamp(COLL_PRAGMA_KEY, get_block_timestamp());

        // called at timeout
        start_cheat_block_timestamp_global(get_block_timestamp() + timeout);
        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);
        assert!(collateral_asset_price.value == SCALE, "Collateral asset price not correctly returned");
        assert!(collateral_asset_price.is_valid, "Collateral asset validity should be true");

        // called at timeout - 1
        start_cheat_block_timestamp_global(get_block_timestamp() - 1);
        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);
        assert!(collateral_asset_price.value == SCALE, "Collateral asset price not correctly returned");
        assert!(collateral_asset_price.is_valid, "Collateral asset validity should be true");
    }

    #[test]
    fn test_is_valid_timeout_stale_price() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        let timeout = 10;

        create_custom_pool(
            users.owner,
            users.curator,
            pool,
            oracle,
            collateral_asset.contract_address,
            debt_asset.contract_address,
            timeout,
            2,
        );

        let pragma_oracle = IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() };
        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };
        pragma_oracle.set_last_updated_timestamp(COLL_PRAGMA_KEY, get_block_timestamp());

        // called at timeout + 1
        start_cheat_block_timestamp_global(get_block_timestamp() + timeout + 1);
        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);
        assert!(collateral_asset_price.value == SCALE, "Collateral asset price not correctly returned");
        // stale price
        assert!(!collateral_asset_price.is_valid, "Collateral asset validity should be false");
    }

    #[test]
    fn test_is_valid_sources_reached() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        let min_number_of_sources = 2;
        create_custom_pool(
            users.owner,
            users.curator,
            pool,
            oracle,
            collateral_asset.contract_address,
            debt_asset.contract_address,
            0,
            min_number_of_sources,
        );

        let pragma_oracle = IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() };
        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };

        // number of sources == min_number_of_sources + 1
        pragma_oracle.set_num_sources_aggregated(COLL_PRAGMA_KEY, min_number_of_sources + 1);

        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);

        assert!(collateral_asset_price.is_valid, "Debt asset validity should be true");

        // number of sources == min_number_of_sources
        pragma_oracle.set_num_sources_aggregated(COLL_PRAGMA_KEY, min_number_of_sources + 1);

        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);

        assert!(collateral_asset_price.is_valid, "Debt asset validity should be true");
    }

    #[test]
    fn test_is_valid_sources_not_reached() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        let min_number_of_sources = 2;
        create_custom_pool(
            users.owner,
            users.curator,
            pool,
            oracle,
            collateral_asset.contract_address,
            debt_asset.contract_address,
            0,
            min_number_of_sources,
        );

        let pragma_oracle = IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() };
        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };

        // number of sources == min_number_of_sources - 1
        pragma_oracle.set_num_sources_aggregated(COLL_PRAGMA_KEY, min_number_of_sources - 1);

        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);

        assert!(!collateral_asset_price.is_valid, "Debt asset validity should be false");
    }

    #[test]
    fn test_price_twap() {
        let (_, oracle, config, _, _) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        store(
            oracle.contract_address,
            map_entry_address(selector!("oracle_configs"), array![collateral_asset.contract_address.into()].span()),
            array![COLL_PRAGMA_KEY, 0, 2, 1, 1, 1].span(),
        );

        store(
            oracle.contract_address,
            map_entry_address(selector!("oracle_configs"), array![debt_asset.contract_address.into()].span()),
            array![DEBT_PRAGMA_KEY, 0, 2, 1, 1, 1].span(),
        );

        let pragma_oracle = IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() };
        let pragma_summary = IMockPragmaSummaryDispatcher { contract_address: oracle.pragma_summary() };
        let price_oracle = IOracleDispatcher { contract_address: oracle.contract_address };

        let max: u128 = Bounded::<u128>::MAX;
        // set collateral asset price
        pragma_oracle.set_price(COLL_PRAGMA_KEY, 1);
        pragma_summary.set_twap(COLL_PRAGMA_KEY, max, 18);
        // set debt asset price
        pragma_oracle.set_price(DEBT_PRAGMA_KEY, 1);
        pragma_summary.set_twap(DEBT_PRAGMA_KEY, max, 18);

        let collateral_asset_price = price_oracle.price(collateral_asset.contract_address);
        let debt_asset_price = price_oracle.price(debt_asset.contract_address);

        assert!(collateral_asset_price.value == max.into(), "Collateral asset price not correctly set");
        assert!(debt_asset_price.value == max.into(), "Debt asset price not correctly set");
        assert!(collateral_asset_price.is_valid, "Debt asset validity should be true");
        assert!(debt_asset_price.is_valid, "Debt asset validity should be true");

        let max_pair_LTV_ratio = 10 * SCALE;
        let check_collat = is_collateralized(collateral_asset_price.value, debt_asset_price.value, max_pair_LTV_ratio);
        assert!(check_collat, "Collateralization check failed");
    }
}
