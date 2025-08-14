#[cfg(test)]
mod TestDefaultExtensionPOV2 {
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::ERC20ABIDispatcherTrait;
    use snforge_std::{
        CheatSpan, DeclareResultTrait, cheat_caller_address, declare, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    #[feature("deprecated-starknet-consts")]
    use starknet::contract_address_const;
    use vesu::data_model::{AssetParams, FeeConfig, LTVConfig};
    use vesu::extension::components::interest_rate_model::InterestRateConfig;
    use vesu::extension::components::position_hooks::{LiquidationConfig, ShutdownConfig, ShutdownMode};
    use vesu::extension::default_extension_po_v2::{IDefaultExtensionPOV2DispatcherTrait, PragmaOracleParams};
    use vesu::singleton_v2::ISingletonV2DispatcherTrait;
    use vesu::test::mock_singleton_upgrade::{IMockSingletonUpgradeDispatcher, IMockSingletonUpgradeDispatcherTrait};
    use vesu::test::setup_v2::{COLL_PRAGMA_KEY, Env, TestConfig, create_pool, deploy_asset, setup_env};
    use vesu::units::{DAY_IN_SECONDS, INFLATION_FEE, PERCENT, SCALE};
    use vesu::vendor::pragma::AggregationMode;

    #[test]
    fn test_create_pool() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let TestConfig { collateral_asset, debt_asset, .. } = config;

        assert!(singleton.extension().is_non_zero(), "Pool not created");

        let ltv = singleton.ltv_config(debt_asset.contract_address, collateral_asset.contract_address).max_ltv;
        assert!(ltv > 0, "Not set");
        let ltv = singleton.ltv_config(collateral_asset.contract_address, debt_asset.contract_address).max_ltv;
        assert!(ltv > 0, "Not set");

        let asset_config = singleton.asset_config(collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
        let asset_config = singleton.asset_config(debt_asset.contract_address);
        assert!(asset_config.floor != 0, "Debt asset config not set");
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_add_asset_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let asset = deploy_asset(users.owner);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
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

        let pragma_oracle_params = PragmaOracleParams {
            pragma_key: COLL_PRAGMA_KEY,
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(()),
        };

        extension.add_asset(asset_params, interest_rate_config, pragma_oracle_params);
    }

    #[test]
    #[should_panic(expected: "oracle-config-already-set")]
    fn test_add_asset_oracle_config_already_set() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
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

        let pragma_oracle_params = PragmaOracleParams {
            pragma_key: COLL_PRAGMA_KEY,
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(()),
        };

        start_cheat_caller_address(config.collateral_asset.contract_address, users.owner);
        config.collateral_asset.approve(extension.contract_address, INFLATION_FEE);
        stop_cheat_caller_address(config.collateral_asset.contract_address);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.add_asset(asset_params, interest_rate_config, pragma_oracle_params);
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    #[should_panic(expected: "pragma-key-must-be-set")]
    fn test_add_asset_pragma_key_must_be_set() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let asset = deploy_asset(users.owner);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
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

        let pragma_oracle_params = PragmaOracleParams {
            pragma_key: Zero::zero(),
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(()),
        };

        start_cheat_caller_address(asset.contract_address, users.owner);
        asset.approve(extension.contract_address, INFLATION_FEE);
        stop_cheat_caller_address(asset.contract_address);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.add_asset(asset_params, interest_rate_config, pragma_oracle_params);
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    fn test_add_asset_po() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let asset = deploy_asset(users.owner);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
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

        let pragma_oracle_params = PragmaOracleParams {
            pragma_key: COLL_PRAGMA_KEY,
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(()),
        };

        start_cheat_caller_address(asset.contract_address, users.owner);
        asset.approve(extension.contract_address, INFLATION_FEE);
        stop_cheat_caller_address(asset.contract_address);

        cheat_caller_address(extension.contract_address, users.owner, CheatSpan::TargetCalls(1));
        extension.add_asset(asset_params, interest_rate_config, pragma_oracle_params);
        stop_cheat_caller_address(extension.contract_address);

        let asset_config = singleton.asset_config(config.collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_asset_parameter_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        extension.set_asset_parameter(config.collateral_asset.contract_address, 'max_utilization', 0);
    }

    #[test]
    fn test_extension_set_asset_parameter() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_asset_parameter(config.collateral_asset.contract_address, 'max_utilization', 0);
        stop_cheat_caller_address(extension.contract_address);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_asset_parameter(config.collateral_asset.contract_address, 'floor', SCALE);
        stop_cheat_caller_address(extension.contract_address);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_asset_parameter(config.collateral_asset.contract_address, 'fee_rate', SCALE);
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    #[should_panic(expected: "caller-not-extension-owner")]
    fn test_set_ltv_config_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        singleton
            .set_ltv_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: (40 * PERCENT).try_into().unwrap() },
            );
    }

    #[test]
    fn test_set_ltv_config() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let ltv_config = LTVConfig { max_ltv: (40 * PERCENT).try_into().unwrap() };

        start_cheat_caller_address(singleton.contract_address, users.owner);
        singleton
            .set_ltv_config(config.collateral_asset.contract_address, config.debt_asset.contract_address, ltv_config);
        stop_cheat_caller_address(singleton.contract_address);

        let ltv_config_ = singleton
            .ltv_config(config.collateral_asset.contract_address, config.debt_asset.contract_address);

        assert(ltv_config_.max_ltv == ltv_config.max_ltv, 'LTV config not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_liquidation_config_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let liquidation_factor = 10 * PERCENT;

        extension
            .set_liquidation_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LiquidationConfig { liquidation_factor: liquidation_factor.try_into().unwrap() },
            );
    }

    #[test]
    fn test_extension_set_liquidation_config() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let liquidation_factor = 10 * PERCENT;

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension
            .set_liquidation_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LiquidationConfig { liquidation_factor: liquidation_factor.try_into().unwrap() },
            );
        stop_cheat_caller_address(extension.contract_address);

        let liquidation_config = extension
            .liquidation_config(config.collateral_asset.contract_address, config.debt_asset.contract_address);

        assert(liquidation_config.liquidation_factor.into() == liquidation_factor, 'liquidation factor not set');
    }

    #[test]
    fn test_extension_set_shutdown_config() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let recovery_period = 11 * DAY_IN_SECONDS;
        let subscription_period = 12 * DAY_IN_SECONDS;

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_shutdown_config(ShutdownConfig { recovery_period, subscription_period });
        stop_cheat_caller_address(extension.contract_address);

        let shutdown_config = extension.shutdown_config();

        assert(shutdown_config.recovery_period == recovery_period, 'recovery period not set');
        assert(shutdown_config.subscription_period == subscription_period, 'subscription period not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_shutdown_config_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let recovery_period = 11 * DAY_IN_SECONDS;
        let subscription_period = 12 * DAY_IN_SECONDS;

        extension.set_shutdown_config(ShutdownConfig { recovery_period, subscription_period });
    }

    #[test]
    fn test_extension_set_shutdown_ltv_config() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let max_ltv = SCALE / 2;

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension
            .set_shutdown_ltv_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: max_ltv.try_into().unwrap() },
            );
        stop_cheat_caller_address(extension.contract_address);

        let shutdown_ltv_config = extension
            .shutdown_ltv_config(config.collateral_asset.contract_address, config.debt_asset.contract_address);

        assert(shutdown_ltv_config.max_ltv == max_ltv.try_into().unwrap(), 'max ltv not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_shutdown_ltv_config_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let max_ltv = SCALE / 2;

        extension
            .set_shutdown_ltv_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: max_ltv.try_into().unwrap() },
            );
    }

    #[test]
    #[should_panic(expected: "invalid-ltv-config")]
    fn test_extension_set_shutdown_ltv_config_invalid_ltv_config() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        let max_ltv = SCALE + 1;

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension
            .set_shutdown_ltv_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: max_ltv.try_into().unwrap() },
            );
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    fn test_extension_set_oracle_parameter() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'timeout', 5_u64.into());
        stop_cheat_caller_address(extension.contract_address);

        let oracle_config = extension.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.timeout == 5_u64, 'timeout not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'number_of_sources', 11_u64.into());
        stop_cheat_caller_address(extension.contract_address);

        let oracle_config = extension.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.number_of_sources == 11, 'number_of_sources not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'start_time_offset', 10_u64.into());
        stop_cheat_caller_address(extension.contract_address);

        let oracle_config = extension.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.start_time_offset == 10, 'start_time_offset not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'time_window', 10_u64.into());
        stop_cheat_caller_address(extension.contract_address);

        let oracle_config = extension.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.time_window == 10, 'time_window not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'aggregation_mode', 'Mean'.into());
        stop_cheat_caller_address(extension.contract_address);

        let oracle_config = extension.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.aggregation_mode == AggregationMode::Mean, 'aggregation_mode not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'pragma_key', '123'.into());
        stop_cheat_caller_address(extension.contract_address);

        let oracle_config = extension.oracle_config(config.collateral_asset.contract_address);
        assert(oracle_config.pragma_key == '123', 'pragma_key not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_oracle_parameter_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'timeout', 5_u64.into());
    }

    #[test]
    #[should_panic(expected: "invalid-oracle-parameter")]
    fn test_extension_set_oracle_parameter_invalid_oracle_parameter() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'a', 5_u64.into());
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    #[should_panic(expected: "oracle-config-not-set")]
    fn test_extension_set_oracle_parameter_oracle_config_not_set() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(Zero::zero(), 'timeout', 5_u64.into());
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    #[should_panic(expected: "time-window-must-be-less-than-start-time-offset")]
    fn test_extension_set_oracle_parameter_time_window_greater_than_start_time_offset() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_oracle_parameter(config.collateral_asset.contract_address, 'time_window', 1_u64.into());
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    fn test_extension_set_interest_rate_parameter() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'min_target_utilization', 5);
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.min_target_utilization == 5, 'Interest rate parameter not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'max_target_utilization', 5);
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.max_target_utilization == 5, 'Interest rate parameter not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'target_utilization', 5);
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.target_utilization == 5, 'Interest rate parameter not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension
            .set_interest_rate_parameter(
                config.collateral_asset.contract_address, 'min_full_utilization_rate', 1582470461,
            );
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.min_full_utilization_rate == 1582470461, 'Interest rate parameter not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension
            .set_interest_rate_parameter(
                config.collateral_asset.contract_address, 'max_full_utilization_rate', SCALE * 3,
            );
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.max_full_utilization_rate == SCALE * 3, 'Interest rate parameter not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'zero_utilization_rate', 1);
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.zero_utilization_rate == 1, 'Interest rate parameter not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'rate_half_life', 5);
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.rate_half_life == 5, 'Interest rate parameter not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'target_rate_percent', 5);
        stop_cheat_caller_address(extension.contract_address);
        let interest_rate_config = extension.interest_rate_config(config.collateral_asset.contract_address);
        assert(interest_rate_config.target_rate_percent == 5, 'Interest rate parameter not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_interest_rate_parameter_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'min_target_utilization', 5);
    }

    #[test]
    #[should_panic(expected: "invalid-interest-rate-parameter")]
    fn test_extension_set_interest_rate_parameter_invalid_interest_rate_parameter() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(config.collateral_asset.contract_address, 'a', 5);
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    #[should_panic(expected: "interest-rate-config-not-set")]
    fn test_extension_set_interest_rate_parameter_interest_rate_config_not_set() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_interest_rate_parameter(Zero::zero(), 'min_target_utilization', 5);
        stop_cheat_caller_address(extension.contract_address);
    }

    #[test]
    fn test_set_fee_config() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(singleton.contract_address, users.owner);
        singleton.set_fee_config(FeeConfig { fee_recipient: users.lender });
        stop_cheat_caller_address(singleton.contract_address);

        let fee_config = singleton.fee_config();
        assert(fee_config.fee_recipient == users.lender, 'Fee config not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_set_fee_config_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        singleton.set_fee_config(FeeConfig { fee_recipient: users.lender });
    }

    #[test]
    fn test_extension_set_debt_cap() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_debt_cap(config.collateral_asset.contract_address, config.debt_asset.contract_address, 1000);
        stop_cheat_caller_address(extension.contract_address);

        assert!(
            extension.debt_caps(config.collateral_asset.contract_address, config.debt_asset.contract_address) == 1000,
        );
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_debt_cap_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        extension.set_debt_cap(config.collateral_asset.contract_address, config.debt_asset.contract_address, 1000);

        assert!(
            extension.debt_caps(config.collateral_asset.contract_address, config.debt_asset.contract_address) == 1000,
        );
    }

    #[test]
    fn test_extension_set_shutdown_mode_agent() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_shutdown_mode_agent(users.lender);
        stop_cheat_caller_address(extension.contract_address);

        let shutdown_mode_agent = extension.shutdown_mode_agent();
        assert(shutdown_mode_agent == users.lender, 'Shutdown mode agent not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_shutdown_mode_agent_caller_not_owner() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        extension.set_shutdown_mode_agent(users.lender);
    }

    #[test]
    fn test_extension_set_shutdown_mode() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_shutdown_mode_agent(users.lender);
        stop_cheat_caller_address(extension.contract_address);

        start_cheat_caller_address(extension.contract_address, users.lender);
        extension.set_shutdown_mode(ShutdownMode::Recovery);
        stop_cheat_caller_address(extension.contract_address);

        let shutdown_status = extension
            .shutdown_status(config.collateral_asset.contract_address, config.debt_asset.contract_address);
        assert(shutdown_status.shutdown_mode == ShutdownMode::Recovery, 'Shutdown mode not set');

        start_cheat_caller_address(extension.contract_address, users.owner);
        extension.set_shutdown_mode(ShutdownMode::None);
        stop_cheat_caller_address(extension.contract_address);

        let shutdown_status = extension
            .shutdown_status(config.collateral_asset.contract_address, config.debt_asset.contract_address);
        assert(shutdown_status.shutdown_mode == ShutdownMode::None, 'Shutdown mode not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner-or-agent")]
    fn test_extension_set_shutdown_mode_caller_not_owner_or_agent() {
        let Env {
            singleton, extension, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(singleton, extension, config, users.owner, Option::None);

        extension.set_shutdown_mode(ShutdownMode::Recovery);
    }

    #[test]
    #[should_panic(expected: "caller-not-singleton-owner")]
    fn test_extension_upgrade_only_owner() {
        let Env { extension, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_class_hash = *declare("MockExtensionPOV2Upgrade").unwrap().contract_class().class_hash;
        start_cheat_caller_address(extension.contract_address, contract_address_const::<'not_owner'>());
        extension.upgrade(new_class_hash);
    }

    #[test]
    fn test_extension_upgrade() {
        let Env { extension, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let new_class_hash = *declare("MockExtensionPOV2Upgrade").unwrap().contract_class().class_hash;
        cheat_caller_address(extension.contract_address, users.owner, CheatSpan::TargetCalls(1));
        extension.upgrade(new_class_hash);
        let tag = IMockSingletonUpgradeDispatcher { contract_address: extension.contract_address }.tag();
        assert!(tag == 'MockExtensionPOV2Upgrade', "Invalid tag");
    }

    #[test]
    #[should_panic(expected: "invalid-upgrade-name")]
    fn test_extension_upgrade_wrong_name() {
        let Env { extension, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_class_hash = *declare("MockSingletonUpgradeWrongName").unwrap().contract_class().class_hash;
        cheat_caller_address(extension.contract_address, users.owner, CheatSpan::TargetCalls(1));
        extension.upgrade(new_class_hash);
    }
}
