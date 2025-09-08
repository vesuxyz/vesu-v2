#[cfg(test)]
mod TestDefaultPOV2 {
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::ERC20ABIDispatcherTrait;
    use snforge_std::{CheatSpan, cheat_caller_address, start_cheat_caller_address, stop_cheat_caller_address};
    #[feature("deprecated-starknet-consts")]
    use vesu::data_model::{AssetParams, PairConfig};
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::oracle::{IPragmaOracleDispatcherTrait, OracleConfig};
    use vesu::pool::IPoolDispatcherTrait;
    use vesu::test::setup_v2::{COLL_PRAGMA_KEY, Env, TestConfig, create_pool, deploy_asset, setup_env};
    use vesu::units::{INFLATION_FEE, PERCENT, SCALE};
    use vesu::vendor::pragma::AggregationMode;

    #[test]
    fn test_create_pool() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        let TestConfig { collateral_asset, debt_asset, .. } = config;

        let ltv = pool.pair_config(debt_asset.contract_address, collateral_asset.contract_address).max_ltv;
        assert!(ltv > 0, "Not set");
        let ltv = pool.pair_config(collateral_asset.contract_address, debt_asset.contract_address).max_ltv;
        assert!(ltv > 0, "Not set");

        let asset_config = pool.asset_config(collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
        let asset_config = pool.asset_config(debt_asset.contract_address);
        assert!(asset_config.floor != 0, "Debt asset config not set");
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_add_asset_not_owner() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        let asset = deploy_asset(users.curator);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        let interest_rate_config = InterestRateConfig {
            min_target_utilization: 75_000,
            max_target_utilization: 85_000,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        };

        pool.add_asset(asset_params, interest_rate_config);
    }

    #[test]
    #[should_panic(expected: "asset-config-already-exists")]
    fn test_add_asset_already_exists() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        let asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        let interest_rate_config = InterestRateConfig {
            min_target_utilization: 75_000,
            max_target_utilization: 85_000,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        };

        start_cheat_caller_address(config.collateral_asset.contract_address, users.curator);
        config.collateral_asset.approve(pool.contract_address, INFLATION_FEE);
        stop_cheat_caller_address(config.collateral_asset.contract_address);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.add_asset(asset_params, interest_rate_config);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "pragma-key-must-be-set")]
    fn test_add_asset_pragma_key_must_be_set() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        let asset = deploy_asset(users.curator);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        let interest_rate_config = InterestRateConfig {
            min_target_utilization: 75_000,
            max_target_utilization: 88_000,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        };

        let oracle_config = OracleConfig {
            pragma_key: Zero::zero(),
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(()),
        };

        start_cheat_caller_address(asset.contract_address, users.curator);
        asset.approve(pool.contract_address, INFLATION_FEE);
        stop_cheat_caller_address(asset.contract_address);

        cheat_caller_address(oracle.contract_address, users.curator, CheatSpan::TargetCalls(1));
        oracle.add_asset(asset.contract_address, oracle_config);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.add_asset(asset_params, interest_rate_config);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "invalid-pragma-key")]
    fn test_add_asset_before_set_oracle() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        let asset = deploy_asset(users.curator);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        let interest_rate_config = InterestRateConfig {
            min_target_utilization: 75_000,
            max_target_utilization: 85_000,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        };

        cheat_caller_address(asset.contract_address, users.curator, CheatSpan::TargetCalls(1));
        asset.approve(pool.contract_address, INFLATION_FEE);

        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.add_asset(asset_params, interest_rate_config);
    }

    #[test]
    fn test_add_asset_po() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        let asset = deploy_asset(users.curator);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

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

        let oracle_config = OracleConfig {
            pragma_key: COLL_PRAGMA_KEY,
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(()),
        };

        cheat_caller_address(asset.contract_address, users.curator, CheatSpan::TargetCalls(1));
        asset.approve(pool.contract_address, INFLATION_FEE);

        cheat_caller_address(oracle.contract_address, users.curator, CheatSpan::TargetCalls(1));
        oracle.add_asset(asset_params.asset, oracle_config);

        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.add_asset(asset_params, interest_rate_config);

        let asset_config = pool.asset_config(config.collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_set_asset_parameter_not_owner() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool.set_asset_parameter(config.collateral_asset.contract_address, 'max_utilization', 0);
    }

    #[test]
    fn test_set_asset_parameter() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_asset_parameter(config.collateral_asset.contract_address, 'max_utilization', 0);
        stop_cheat_caller_address(pool.contract_address);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_asset_parameter(config.collateral_asset.contract_address, 'floor', SCALE);
        stop_cheat_caller_address(pool.contract_address);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_asset_parameter(config.collateral_asset.contract_address, 'fee_rate', SCALE);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_set_pair_config_caller_not_owner() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool
            .set_pair_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                PairConfig { max_ltv: (40 * PERCENT).try_into().unwrap(), liquidation_factor: 0, debt_cap: 0 },
            );
    }

    #[test]
    #[should_panic(expected: "identical-assets")]
    fn test_set_pair_config_identical_assets() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_config(
                config.collateral_asset.contract_address,
                config.collateral_asset.contract_address,
                PairConfig { max_ltv: (40 * PERCENT).try_into().unwrap(), liquidation_factor: 0, debt_cap: 0 },
            );
    }

    #[test]
    #[should_panic(expected: "max-ltv-exceeded")]
    fn test_set_pair_config_max_ltv_exceeded() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                PairConfig { max_ltv: (SCALE + 1).try_into().unwrap(), liquidation_factor: 0, debt_cap: 0 },
            );
    }

    #[test]
    #[should_panic(expected: "liquidation-factor-exceeded")]
    fn test_set_pair_config_liquidation_factor_exceeded() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                PairConfig {
                    max_ltv: (40 * PERCENT).try_into().unwrap(),
                    liquidation_factor: (SCALE + 1).try_into().unwrap(),
                    debt_cap: 0,
                },
            );
    }

    #[test]
    fn test_set_pair_config() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        let pair_config = PairConfig {
            max_ltv: (40 * PERCENT).try_into().unwrap(),
            liquidation_factor: (10 * PERCENT).try_into().unwrap(),
            debt_cap: 10000_u128,
        };

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_pair_config(config.collateral_asset.contract_address, config.debt_asset.contract_address, pair_config);
        stop_cheat_caller_address(pool.contract_address);

        let pair_config_ = pool
            .pair_config(config.collateral_asset.contract_address, config.debt_asset.contract_address);
        assert(pair_config_.max_ltv == pair_config.max_ltv, 'LTV config not set');
        assert(pair_config_.liquidation_factor == pair_config.liquidation_factor, 'Liquidation factor not set');
        assert(pair_config_.debt_cap == pair_config.debt_cap, 'Debt cap not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_set_pair_parameter_caller_not_curator() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                'max_ltv',
                (40 * PERCENT).try_into().unwrap(),
            );
    }

    #[test]
    #[should_panic(expected: "identical-assets")]
    fn test_set_pair_parameter_identical_assets() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address,
                config.collateral_asset.contract_address,
                'max_ltv',
                (40 * PERCENT).try_into().unwrap(),
            );
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "invalid-pair-parameter")]
    fn test_set_pair_parameter_invalid_pair_parameter() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                'a',
                (40 * PERCENT).try_into().unwrap(),
            );
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "max-ltv-exceeded")]
    fn test_set_pair_parameter_max_ltv_exceeded() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                'max_ltv',
                (SCALE + 1).try_into().unwrap(),
            );
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "liquidation-factor-exceeded")]
    fn test_set_pair_parameter_liquidation_factor_exceeded() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                'liquidation_factor',
                (SCALE + 1).try_into().unwrap(),
            );
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    fn test_set_pair_parameter() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                'max_ltv',
                (40 * PERCENT).try_into().unwrap(),
            );
        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                'liquidation_factor',
                (10 * PERCENT).try_into().unwrap(),
            );
        pool
            .set_pair_parameter(
                config.collateral_asset.contract_address, config.debt_asset.contract_address, 'debt_cap', 10000_u128,
            );
        stop_cheat_caller_address(pool.contract_address);

        let pair_config = pool
            .pair_config(config.collateral_asset.contract_address, config.debt_asset.contract_address);
        assert(pair_config.max_ltv == (40 * PERCENT).try_into().unwrap(), 'LTV config not set');
        assert(pair_config.liquidation_factor == pair_config.liquidation_factor, 'Liquidation factor not set');
        assert(pair_config.debt_cap == pair_config.debt_cap, 'Debt cap not set');
    }

    #[test]
    fn test_set_oracle_parameter() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'timeout', 5_u64.into());
        stop_cheat_caller_address(oracle.contract_address);

        let oracle_config = oracle.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.timeout == 5_u64, 'timeout not set');

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'number_of_sources', 11_u64.into());
        stop_cheat_caller_address(oracle.contract_address);

        let oracle_config = oracle.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.number_of_sources == 11, 'number_of_sources not set');

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'start_time_offset', 10_u64.into());
        stop_cheat_caller_address(oracle.contract_address);

        let oracle_config = oracle.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.start_time_offset == 10, 'start_time_offset not set');

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'time_window', 10_u64.into());
        stop_cheat_caller_address(oracle.contract_address);

        let oracle_config = oracle.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.time_window == 10, 'time_window not set');

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'aggregation_mode', 'Mean'.into());
        stop_cheat_caller_address(oracle.contract_address);

        let oracle_config = oracle.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.aggregation_mode == AggregationMode::Mean, 'aggregation_mode not set');

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'pragma_key', '123'.into());
        stop_cheat_caller_address(oracle.contract_address);

        let oracle_config = oracle.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.pragma_key == '123', 'pragma_key not set');
    }

    #[test]
    #[should_panic(expected: "oracle-already-set")]
    fn test_add_existed_asset() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(oracle.contract_address, users.curator, CheatSpan::TargetCalls(1));
        oracle
            .add_asset(
                asset: config.collateral_asset.contract_address,
                oracle_config: OracleConfig {
                    pragma_key: COLL_PRAGMA_KEY,
                    timeout: 1,
                    number_of_sources: 2,
                    start_time_offset: 0,
                    time_window: 0,
                    aggregation_mode: AggregationMode::Median(()),
                },
            );
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_set_oracle_parameter_caller_not_manager() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'timeout', 5_u64.into());
    }

    #[test]
    #[should_panic(expected: "invalid-oracle-parameter")]
    fn test_set_oracle_parameter_invalid_oracle_parameter() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'a', 5_u64.into());
        stop_cheat_caller_address(oracle.contract_address);
    }

    #[test]
    #[should_panic(expected: "oracle-config-not-set")]
    fn test_set_oracle_parameter_oracle_config_not_set() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(Zero::zero(), 'timeout', 5_u64.into());
        stop_cheat_caller_address(oracle.contract_address);
    }

    #[test]
    #[should_panic(expected: "time-window-must-be-less-than-start-time-offset")]
    fn test_set_oracle_parameter_time_window_greater_than_start_time_offset() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(oracle.contract_address, users.curator);
        oracle.set_oracle_parameter(config.collateral_asset.contract_address, 'time_window', 1_u64.into());
        stop_cheat_caller_address(oracle.contract_address);
    }

    #[test]
    fn test_set_interest_rate_parameter() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'min_target_utilization', 5);
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.min_target_utilization == 5, 'Interest rate parameter not set');

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'max_target_utilization', 90_000);
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.max_target_utilization == 90_000, 'Interest rate parameter not set');

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'target_utilization', 5);
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.target_utilization == 5, 'Interest rate parameter not set');

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_interest_rate_parameter(
                config.collateral_asset.contract_address, 'min_full_utilization_rate', 1582470461,
            );
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.min_full_utilization_rate == 1582470461, 'Interest rate parameter not set');

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool
            .set_interest_rate_parameter(
                config.collateral_asset.contract_address, 'max_full_utilization_rate', SCALE * 3,
            );
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.max_full_utilization_rate == SCALE * 3, 'Interest rate parameter not set');

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'zero_utilization_rate', 1);
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.zero_utilization_rate == 1, 'Interest rate parameter not set');

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'rate_half_life', 5);
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.rate_half_life == 5, 'Interest rate parameter not set');

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'target_rate_percent', 5);
        stop_cheat_caller_address(pool.contract_address);
        let interest_rate_config = pool.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.target_rate_percent == 5, 'Interest rate parameter not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_set_interest_rate_parameter_caller_not_owner() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'min_target_utilization', 5);
    }

    #[test]
    #[should_panic(expected: "invalid-interest-rate-parameter")]
    fn test_set_interest_rate_parameter_invalid_interest_rate_parameter() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(config.collateral_asset.contract_address, 'a', 5);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "asset-config-nonexistent")]
    fn test_set_interest_rate_parameter_non_existent_asset() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_interest_rate_parameter(Zero::zero(), 'min_target_utilization', 5);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    fn test_set_fee_recipient() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_fee_recipient(users.lender);
        stop_cheat_caller_address(pool.contract_address);

        let fee_recipient = pool.fee_recipient();
        assert(fee_recipient == users.lender, 'Fee recipient not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_set_fee_recipient_caller_not_owner() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool.set_fee_recipient(users.lender);
    }

    #[test]
    fn test_set_pausing_agent() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_pausing_agent(users.lender);
        stop_cheat_caller_address(pool.contract_address);

        let pausing_agent = pool.pausing_agent();
        assert(pausing_agent == users.lender, 'Pausing agent not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_set_pausing_agent_caller_not_owner() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool.set_pausing_agent(users.lender);
    }

    #[test]
    fn test_pool_set_curator() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.nominate_curator(users.lender);

        assert(pool.pending_curator() == users.lender, 'Nominated curator not set');
        assert(pool.curator() == users.curator, 'Curator was set');

        cheat_caller_address(pool.contract_address, users.lender, CheatSpan::TargetCalls(1));
        pool.accept_curator_ownership();

        assert(pool.pending_curator() == Zero::zero(), 'Nominated curator not reset');
        assert(pool.curator() == users.lender, 'Curator not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_pool_nominate_curator_caller_not_curator() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool.nominate_curator(users.lender);
    }

    #[test]
    #[should_panic(expected: "caller-not-new-curator")]
    fn test_pool_accept_zero_curator_different_caller() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(pool.contract_address, users.lender, CheatSpan::TargetCalls(1));
        pool.accept_curator_ownership();
    }

    #[test]
    #[should_panic(expected: "invalid-zero-curator-address")]
    fn test_pool_accept_zero_curator() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(pool.contract_address, Zero::zero(), CheatSpan::TargetCalls(1));
        pool.accept_curator_ownership();
    }

    #[test]
    fn test_oracle_set_manager() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(oracle.contract_address, users.curator, CheatSpan::TargetCalls(1));
        oracle.nominate_manager(users.lender);

        assert(oracle.pending_manager() == users.lender, 'Nominated manager not set');
        assert(oracle.manager() == users.curator, 'Curator was set');

        cheat_caller_address(oracle.contract_address, users.lender, CheatSpan::TargetCalls(1));
        oracle.accept_manager_ownership();

        assert(oracle.pending_manager() == Zero::zero(), 'Nominated manager not reset');
        assert(oracle.manager() == users.lender, 'Curator not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-manager")]
    fn test_oracle_nominate_manager_caller_not_manager() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        oracle.nominate_manager(users.lender);
    }

    #[test]
    #[should_panic(expected: "caller-not-new-manager")]
    fn test_oracle_accept_zero_manager_different_caller() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(oracle.contract_address, users.lender, CheatSpan::TargetCalls(1));
        oracle.accept_manager_ownership();
    }

    #[test]
    #[should_panic(expected: "invalid-zero-manager-address")]
    fn test_oracle_accept_zero_manager() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(oracle.contract_address, Zero::zero(), CheatSpan::TargetCalls(1));
        oracle.accept_manager_ownership();
    }

    #[test]
    fn test_pause_pool() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_pausing_agent(users.lender);
        stop_cheat_caller_address(pool.contract_address);

        // agent
        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.pause();
        stop_cheat_caller_address(pool.contract_address);

        assert(pool.is_paused(), 'Not paused');

        // curator
        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.unpause();
        stop_cheat_caller_address(pool.contract_address);

        assert(!pool.is_paused(), 'Not unpaused');

        // owner
        start_cheat_caller_address(pool.contract_address, users.owner);
        pool.pause();
        stop_cheat_caller_address(pool.contract_address);

        assert(pool.is_paused(), 'Not paused');
    }

    #[test]
    #[should_panic(expected: "caller-not-authorized")]
    fn test_pause_pool_caller_not_authorized() {
        let Env { pool, oracle, config, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(pool, oracle, config, users.owner, users.curator, Option::None);

        pool.pause();
    }
}
