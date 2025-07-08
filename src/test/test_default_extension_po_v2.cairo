#[cfg(test)]
mod TestDefaultExtensionPOV2 {
    use snforge_std::{start_prank, stop_prank, CheatTarget, get_class_hash, ContractClass, declare, prank, CheatSpan};
    use starknet::{get_contract_address, contract_address_const};
    use vesu::{
        units::{SCALE, SCALE_128, PERCENT, DAY_IN_SECONDS, INFLATION_FEE},
        data_model::{AssetParams, LTVParams, LTVConfig}, singleton_v2::{ISingletonV2DispatcherTrait},
        extension::default_extension_po_v2::{
            InterestRateConfig, PragmaOracleParams, IDefaultExtensionPOV2DispatcherTrait, ShutdownParams, FeeParams,
            VTokenParams, LiquidationConfig, ShutdownConfig, FeeConfig, ShutdownMode
        },
        vendor::{erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait}, pragma::{AggregationMode}},
        test::mock_singleton_upgrade::{IMockSingletonUpgradeDispatcher, IMockSingletonUpgradeDispatcherTrait},
        test::setup_v2::{
            setup_env, create_pool, TestConfig, deploy_assets, deploy_asset, Env, COLL_PRAGMA_KEY,
            test_interest_rate_config
        },
    };

    #[test]
    fn test_create_pool() {
        let Env { singleton, extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero(),
        );

        let old_creator_nonce = singleton.creator_nonce(extension.contract_address);

        create_pool(extension, config, users.creator, Option::None);

        let new_creator_nonce = singleton.creator_nonce(extension.contract_address);
        assert!(new_creator_nonce == old_creator_nonce + 1, "Creator nonce not incremented");

        let TestConfig { pool_id, collateral_asset, debt_asset, .. } = config;

        assert!(singleton.extension(pool_id).is_non_zero(), "Pool not created");

        let ltv = singleton.ltv_config(pool_id, debt_asset.contract_address, collateral_asset.contract_address).max_ltv;
        assert!(ltv > 0, "Not set");
        let ltv = singleton.ltv_config(pool_id, collateral_asset.contract_address, debt_asset.contract_address).max_ltv;
        assert!(ltv > 0, "Not set");

        let (asset_config, _) = singleton.asset_config(pool_id, collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
        let (asset_config, _) = singleton.asset_config(pool_id, debt_asset.contract_address);
        assert!(asset_config.floor != 0, "Debt asset config not set");
    }

    #[test]
    #[should_panic(expected: "empty-asset-params")]
    fn test_create_pool_empty_asset_params() {
        let Env { extension, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero(),
        );

        let asset_params = array![].span();
        let v_token_params = array![].span();
        let max_position_ltv_params = array![].span();
        let interest_rate_configs = array![].span();
        let oracle_params = array![].span();
        let liquidation_params = array![].span();
        let debt_caps_params = array![].span();
        let shutdown_ltv_params = array![].span();
        let shutdown_params = ShutdownParams {
            recovery_period: DAY_IN_SECONDS, subscription_period: DAY_IN_SECONDS, ltv_params: shutdown_ltv_params
        };

        prank(CheatTarget::One(extension.contract_address), users.creator, CheatSpan::TargetCalls(1));
        extension
            .create_pool(
                'DefaultExtensionPOV2',
                asset_params,
                v_token_params,
                max_position_ltv_params,
                interest_rate_configs,
                oracle_params,
                liquidation_params,
                debt_caps_params,
                shutdown_params,
                FeeParams { fee_recipient: users.creator },
                users.creator
            );
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "interest-rate-params-mismatch")]
    fn test_create_pool_interest_rate_params_mismatch() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero(),
        );

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: true,
            fee_rate: 0
        };

        let collateral_asset_v_token_params = VTokenParams { v_token_name: 'Vesu Collateral', v_token_symbol: 'vCOLL' };

        let asset_params = array![collateral_asset_params].span();
        let v_token_params = array![collateral_asset_v_token_params].span();
        let max_position_ltv_params = array![].span();
        let interest_rate_configs = array![].span();
        let oracle_params = array![].span();
        let liquidation_params = array![].span();
        let debt_caps_params = array![].span();
        let shutdown_ltv_params = array![].span();
        let shutdown_params = ShutdownParams {
            recovery_period: DAY_IN_SECONDS, subscription_period: DAY_IN_SECONDS, ltv_params: shutdown_ltv_params
        };

        start_prank(CheatTarget::One(config.collateral_asset.contract_address), users.creator);
        config.collateral_asset.approve(extension.contract_address, INFLATION_FEE);
        stop_prank(CheatTarget::One(config.collateral_asset.contract_address));

        prank(CheatTarget::One(extension.contract_address), users.creator, CheatSpan::TargetCalls(1));
        extension
            .create_pool(
                'DefaultExtensionPOV2',
                asset_params,
                v_token_params,
                max_position_ltv_params,
                interest_rate_configs,
                oracle_params,
                liquidation_params,
                debt_caps_params,
                shutdown_params,
                FeeParams { fee_recipient: users.creator },
                users.creator
            );
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "pragma-oracle-params-mismatch")]
    fn test_create_pool_pragma_oracle_params_mismatch() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero(),
        );

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: true,
            fee_rate: 0
        };

        let collateral_asset_v_token_params = VTokenParams { v_token_name: 'Vesu Collateral', v_token_symbol: 'vCOLL' };

        let asset_params = array![collateral_asset_params].span();
        let v_token_params = array![collateral_asset_v_token_params].span();
        let max_position_ltv_params = array![].span();
        let interest_rate_configs = array![test_interest_rate_config()].span();
        let oracle_params = array![].span();
        let liquidation_params = array![].span();
        let debt_caps_params = array![].span();
        let shutdown_ltv_params = array![].span();
        let shutdown_params = ShutdownParams {
            recovery_period: DAY_IN_SECONDS, subscription_period: DAY_IN_SECONDS, ltv_params: shutdown_ltv_params
        };

        start_prank(CheatTarget::One(config.collateral_asset.contract_address), users.creator);
        config.collateral_asset.approve(extension.contract_address, INFLATION_FEE);
        stop_prank(CheatTarget::One(config.collateral_asset.contract_address));

        prank(CheatTarget::One(extension.contract_address), users.creator, CheatSpan::TargetCalls(1));
        extension
            .create_pool(
                'DefaultExtensionPOV2',
                asset_params,
                v_token_params,
                max_position_ltv_params,
                interest_rate_configs,
                oracle_params,
                liquidation_params,
                debt_caps_params,
                shutdown_params,
                FeeParams { fee_recipient: users.creator },
                users.creator
            );
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "v-token-params-mismatch")]
    fn test_create_pool_v_token_params_mismatch() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero(),
        );

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: true,
            fee_rate: 0
        };

        let collateral_asset_oracle_params = PragmaOracleParams {
            pragma_key: COLL_PRAGMA_KEY,
            timeout: 0,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(())
        };

        let asset_params = array![collateral_asset_params].span();
        let v_token_params = array![].span();
        let max_position_ltv_params = array![].span();
        let interest_rate_configs = array![test_interest_rate_config()].span();
        let oracle_params = array![collateral_asset_oracle_params].span();
        let liquidation_params = array![].span();
        let debt_caps_params = array![].span();
        let shutdown_ltv_params = array![].span();
        let shutdown_params = ShutdownParams {
            recovery_period: DAY_IN_SECONDS, subscription_period: DAY_IN_SECONDS, ltv_params: shutdown_ltv_params
        };

        start_prank(CheatTarget::One(config.collateral_asset.contract_address), users.creator);
        config.collateral_asset.approve(extension.contract_address, INFLATION_FEE);
        stop_prank(CheatTarget::One(config.collateral_asset.contract_address));

        prank(CheatTarget::One(extension.contract_address), users.creator, CheatSpan::TargetCalls(1));
        extension
            .create_pool(
                'DefaultExtensionPOV2',
                asset_params,
                v_token_params,
                max_position_ltv_params,
                interest_rate_configs,
                oracle_params,
                liquidation_params,
                debt_caps_params,
                shutdown_params,
                FeeParams { fee_recipient: users.creator },
                users.creator
            );
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_add_asset_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let asset = deploy_asset(
            ContractClass { class_hash: get_class_hash(config.collateral_asset.contract_address) }, users.creator
        );

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        let v_token_params = VTokenParams { v_token_name: 'Vesu Collateral', v_token_symbol: 'vCOLL' };

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
            aggregation_mode: AggregationMode::Median(())
        };

        extension.add_asset(config.pool_id, asset_params, v_token_params, interest_rate_config, pragma_oracle_params);
    }

    #[test]
    #[should_panic(expected: "oracle-config-already-set")]
    fn test_add_asset_oracle_config_already_set() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        let v_token_params = VTokenParams { v_token_name: 'Vesu Collateral', v_token_symbol: 'vCOLL' };

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
            aggregation_mode: AggregationMode::Median(())
        };

        start_prank(CheatTarget::One(config.collateral_asset.contract_address), users.creator);
        config.collateral_asset.approve(extension.contract_address, INFLATION_FEE);
        stop_prank(CheatTarget::One(config.collateral_asset.contract_address));

        prank(CheatTarget::One(extension.contract_address), users.creator, CheatSpan::TargetCalls(1));
        extension.add_asset(config.pool_id, asset_params, v_token_params, interest_rate_config, pragma_oracle_params);
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "pragma-key-must-be-set")]
    fn test_add_asset_pragma_key_must_be_set() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let asset = deploy_asset(
            ContractClass { class_hash: get_class_hash(config.collateral_asset.contract_address) }, users.creator
        );

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        let v_token_params = VTokenParams { v_token_name: 'Vesu Collateral', v_token_symbol: 'vCOLL' };

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
            pragma_key: Zeroable::zero(),
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(())
        };

        start_prank(CheatTarget::One(asset.contract_address), users.creator);
        asset.approve(extension.contract_address, INFLATION_FEE);
        stop_prank(CheatTarget::One(asset.contract_address));

        prank(CheatTarget::One(extension.contract_address), users.creator, CheatSpan::TargetCalls(1));
        extension.add_asset(config.pool_id, asset_params, v_token_params, interest_rate_config, pragma_oracle_params);
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    fn test_add_asset_po() {
        let Env { singleton, extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let asset = deploy_asset(
            ContractClass { class_hash: get_class_hash(config.collateral_asset.contract_address) }, users.creator
        );

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        let v_token_params = VTokenParams { v_token_name: 'Vesu Collateral', v_token_symbol: 'vCOLL' };

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
            aggregation_mode: AggregationMode::Median(())
        };

        start_prank(CheatTarget::One(asset.contract_address), users.creator);
        asset.approve(extension.contract_address, INFLATION_FEE);
        stop_prank(CheatTarget::One(asset.contract_address));

        prank(CheatTarget::One(extension.contract_address), users.creator, CheatSpan::TargetCalls(1));
        extension.add_asset(config.pool_id, asset_params, v_token_params, interest_rate_config, pragma_oracle_params);
        stop_prank(CheatTarget::One(extension.contract_address));

        let (asset_config, _) = singleton.asset_config(config.pool_id, config.collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_asset_parameter_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'max_utilization', 0);
    }

    #[test]
    fn test_extension_set_asset_parameter() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'max_utilization', 0);
        stop_prank(CheatTarget::One(extension.contract_address));

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'floor', SCALE);
        stop_prank(CheatTarget::One(extension.contract_address));

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'fee_rate', SCALE);
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_set_pool_owner_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension.set_pool_owner(config.pool_id, users.lender);
    }

    #[test]
    fn test_set_pool_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_pool_owner(config.pool_id, users.lender);
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_set_ltv_config_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension
            .set_ltv_config(
                config.pool_id,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: (40 * PERCENT).try_into().unwrap() }
            );
    }

    #[test]
    fn test_extension_set_ltv_config() {
        let Env { singleton, extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let ltv_config = LTVConfig { max_ltv: (40 * PERCENT).try_into().unwrap() };

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_ltv_config(
                config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address, ltv_config
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        let ltv_config_ = singleton
            .ltv_config(config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address);

        assert(ltv_config_.max_ltv == ltv_config.max_ltv, 'LTV config not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_liquidation_config_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let liquidation_factor = 10 * PERCENT;

        extension
            .set_liquidation_config(
                config.pool_id,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LiquidationConfig { liquidation_factor: liquidation_factor.try_into().unwrap() }
            );
    }

    #[test]
    fn test_extension_set_liquidation_config() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let liquidation_factor = 10 * PERCENT;

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_liquidation_config(
                config.pool_id,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LiquidationConfig { liquidation_factor: liquidation_factor.try_into().unwrap() }
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        let liquidation_config = extension
            .liquidation_config(
                config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address
            );

        assert(liquidation_config.liquidation_factor.into() == liquidation_factor, 'liquidation factor not set');
    }

    #[test]
    fn test_extension_set_shutdown_config() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let recovery_period = 11 * DAY_IN_SECONDS;
        let subscription_period = 12 * DAY_IN_SECONDS;

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_shutdown_config(config.pool_id, ShutdownConfig { recovery_period, subscription_period });
        stop_prank(CheatTarget::One(extension.contract_address));

        let shutdown_config = extension.shutdown_config(config.pool_id);

        assert(shutdown_config.recovery_period == recovery_period, 'recovery period not set');
        assert(shutdown_config.subscription_period == subscription_period, 'subscription period not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_shutdown_config_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let recovery_period = 11 * DAY_IN_SECONDS;
        let subscription_period = 12 * DAY_IN_SECONDS;

        extension.set_shutdown_config(config.pool_id, ShutdownConfig { recovery_period, subscription_period });
    }

    #[test]
    #[should_panic(expected: "invalid-shutdown-config")]
    fn test_extension_set_shutdown_config_invalid_shutdown_config() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let recovery_period = 11 * DAY_IN_SECONDS;
        let subscription_period = DAY_IN_SECONDS / 2;

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_shutdown_config(config.pool_id, ShutdownConfig { recovery_period, subscription_period });
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    fn test_extension_set_shutdown_ltv_config() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let max_ltv = SCALE / 2;

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_shutdown_ltv_config(
                config.pool_id,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: max_ltv.try_into().unwrap() }
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        let shutdown_ltv_config = extension
            .shutdown_ltv_config(
                config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address
            );

        assert(shutdown_ltv_config.max_ltv == max_ltv.try_into().unwrap(), 'max ltv not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_shutdown_ltv_config_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let max_ltv = SCALE / 2;

        extension
            .set_shutdown_ltv_config(
                config.pool_id,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: max_ltv.try_into().unwrap() }
            );
    }

    #[test]
    #[should_panic(expected: "invalid-ltv-config")]
    fn test_extension_set_shutdown_ltv_config_invalid_ltv_config() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        let max_ltv = SCALE + 1;

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_shutdown_ltv_config(
                config.pool_id,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: max_ltv.try_into().unwrap() }
            );
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    fn test_extension_set_oracle_parameter() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_oracle_parameter(config.pool_id, config.collateral_asset.contract_address, 'timeout', 5_u64.into());
        stop_prank(CheatTarget::One(extension.contract_address));

        let oracle_config = extension.oracle_config(config.pool_id, config.collateral_asset.contract_address);
        assert(oracle_config.timeout == 5_u64, 'timeout not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_oracle_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'number_of_sources', 11_u64.into()
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        let oracle_config = extension.oracle_config(config.pool_id, config.collateral_asset.contract_address);
        assert(oracle_config.number_of_sources == 11, 'number_of_sources not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_oracle_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'start_time_offset', 10_u64.into()
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        let oracle_config = extension.oracle_config(config.pool_id, config.collateral_asset.contract_address);
        assert(oracle_config.start_time_offset == 10, 'start_time_offset not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_oracle_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'time_window', 10_u64.into()
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        let oracle_config = extension.oracle_config(config.pool_id, config.collateral_asset.contract_address);
        assert(oracle_config.time_window == 10, 'time_window not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_oracle_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'aggregation_mode', 'Mean'.into()
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        let oracle_config = extension.oracle_config(config.pool_id, config.collateral_asset.contract_address);
        assert(oracle_config.aggregation_mode == AggregationMode::Mean, 'aggregation_mode not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_oracle_parameter(config.pool_id, config.collateral_asset.contract_address, 'pragma_key', '123'.into());
        stop_prank(CheatTarget::One(extension.contract_address));

        let oracle_config = extension.oracle_config(config.pool_id, config.collateral_asset.contract_address);
        assert(oracle_config.pragma_key == '123', 'pragma_key not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_oracle_parameter_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension
            .set_oracle_parameter(config.pool_id, config.collateral_asset.contract_address, 'timeout', 5_u64.into());
    }

    #[test]
    #[should_panic(expected: "invalid-oracle-parameter")]
    fn test_extension_set_oracle_parameter_invalid_oracle_parameter() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_oracle_parameter(config.pool_id, config.collateral_asset.contract_address, 'a', 5_u64.into());
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "oracle-config-not-set")]
    fn test_extension_set_oracle_parameter_oracle_config_not_set() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_oracle_parameter(config.pool_id, Zeroable::zero(), 'timeout', 5_u64.into());
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "time-window-must-be-less-than-start-time-offset")]
    fn test_extension_set_oracle_parameter_time_window_greater_than_start_time_offset() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_oracle_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'time_window', 1_u64.into()
            );
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    fn test_extension_set_interest_rate_parameter() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'min_target_utilization', 5
            );
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.min_target_utilization == 5, 'Interest rate parameter not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'max_target_utilization', 5
            );
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.max_target_utilization == 5, 'Interest rate parameter not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'target_utilization', 5
            );
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.target_utilization == 5, 'Interest rate parameter not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'min_full_utilization_rate', 1582470461
            );
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.min_full_utilization_rate == 1582470461, 'Interest rate parameter not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'max_full_utilization_rate', SCALE * 3
            );
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.max_full_utilization_rate == SCALE * 3, 'Interest rate parameter not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'zero_utilization_rate', 1
            );
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.zero_utilization_rate == 1, 'Interest rate parameter not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(config.pool_id, config.collateral_asset.contract_address, 'rate_half_life', 5);
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.rate_half_life == 5, 'Interest rate parameter not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'target_rate_percent', 5
            );
        stop_prank(CheatTarget::One(extension.contract_address));
        let interest_rate_config = extension
            .interest_rate_config(config.pool_id, config.collateral_asset.contract_address);
        assert(interest_rate_config.target_rate_percent == 5, 'Interest rate parameter not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_interest_rate_parameter_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension
            .set_interest_rate_parameter(
                config.pool_id, config.collateral_asset.contract_address, 'min_target_utilization', 5
            );
    }

    #[test]
    #[should_panic(expected: "invalid-interest-rate-parameter")]
    fn test_extension_set_interest_rate_parameter_invalid_interest_rate_parameter() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_interest_rate_parameter(config.pool_id, config.collateral_asset.contract_address, 'a', 5);
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    #[should_panic(expected: "interest-rate-config-not-set")]
    fn test_extension_set_interest_rate_parameter_interest_rate_config_not_set() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_interest_rate_parameter(config.pool_id, Zeroable::zero(), 'min_target_utilization', 5);
        stop_prank(CheatTarget::One(extension.contract_address));
    }

    #[test]
    fn test_extension_set_fee_config() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_fee_config(config.pool_id, FeeConfig { fee_recipient: users.lender });
        stop_prank(CheatTarget::One(extension.contract_address));

        let fee_config = extension.fee_config(config.pool_id);
        assert(fee_config.fee_recipient == users.lender, 'Fee config not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_fee_config_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension.set_fee_config(config.pool_id, FeeConfig { fee_recipient: users.lender });
    }

    #[test]
    fn test_extension_set_debt_cap() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension
            .set_debt_cap(
                config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address, 1000
            );
        stop_prank(CheatTarget::One(extension.contract_address));

        assert!(
            extension
                .debt_caps(
                    config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address
                ) == 1000
        );
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_debt_cap_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension
            .set_debt_cap(
                config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address, 1000
            );

        assert!(
            extension
                .debt_caps(
                    config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address
                ) == 1000
        );
    }

    #[test]
    fn test_extension_set_shutdown_mode_agent() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_shutdown_mode_agent(config.pool_id, users.lender);
        stop_prank(CheatTarget::One(extension.contract_address));

        let shutdown_mode_agent = extension.shutdown_mode_agent(config.pool_id);
        assert(shutdown_mode_agent == users.lender, 'Shutdown mode agent not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_extension_set_shutdown_mode_agent_caller_not_owner() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension.set_shutdown_mode_agent(config.pool_id, users.lender);
    }

    #[test]
    fn test_extension_set_shutdown_mode() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_shutdown_mode_agent(config.pool_id, users.lender);
        stop_prank(CheatTarget::One(extension.contract_address));

        start_prank(CheatTarget::One(extension.contract_address), users.lender);
        extension.set_shutdown_mode(config.pool_id, ShutdownMode::Recovery);
        stop_prank(CheatTarget::One(extension.contract_address));

        let shutdown_status = extension
            .shutdown_status(
                config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address
            );
        assert(shutdown_status.shutdown_mode == ShutdownMode::Recovery, 'Shutdown mode not set');

        start_prank(CheatTarget::One(extension.contract_address), users.creator);
        extension.set_shutdown_mode(config.pool_id, ShutdownMode::None);
        stop_prank(CheatTarget::One(extension.contract_address));

        let shutdown_status = extension
            .shutdown_status(
                config.pool_id, config.collateral_asset.contract_address, config.debt_asset.contract_address
            );
        assert(shutdown_status.shutdown_mode == ShutdownMode::None, 'Shutdown mode not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner-or-agent")]
    fn test_extension_set_shutdown_mode_caller_not_owner_or_agent() {
        let Env { extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        extension.set_shutdown_mode(config.pool_id, ShutdownMode::Recovery);
    }

    #[test]
    #[should_panic(expected: "caller-not-singleton-owner")]
    fn test_extension_upgrade_only_owner() {
        let Env { extension, .. } = setup_env(Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero());
        let new_classhash = declare("MockExtensionPOV2Upgrade").class_hash;
        start_prank(CheatTarget::One(extension.contract_address), contract_address_const::<'not_owner'>());
        extension.upgrade(new_classhash);
    }

    #[test]
    fn test_extension_upgrade() {
        let Env { extension, .. } = setup_env(Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero());

        let new_classhash = declare("MockExtensionPOV2Upgrade").class_hash;
        extension.upgrade(new_classhash);
        let tag = IMockSingletonUpgradeDispatcher { contract_address: extension.contract_address }.tag();
        assert!(tag == 'MockExtensionPOV2Upgrade', "Invalid tag");
    }

    #[test]
    #[should_panic(expected: "invalid-upgrade-name")]
    fn test_extension_upgrade_wrong_name() {
        let Env { extension, .. } = setup_env(Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero());
        let new_classhash = declare("MockSingletonUpgradeWrongName").class_hash;
        extension.upgrade(new_classhash);
    }
}
