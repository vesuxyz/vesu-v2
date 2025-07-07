#[cfg(test)]
mod TestSingletonV2 {
    use snforge_std::{start_prank, stop_prank, CheatTarget, get_class_hash, ContractClass, declare, start_warp};
    use starknet::{get_contract_address, get_block_timestamp, contract_address_const};
    use vesu::{
        units::{SCALE, SCALE_128, PERCENT, DAY_IN_SECONDS},
        data_model::{AssetParams, LTVParams, LTVConfig, ModifyPositionParams, Amount, AmountType, AmountDenomination},
        singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait},
        extension::default_extension_po_v2::{
            IDefaultExtensionPOV2Dispatcher, IDefaultExtensionPOV2DispatcherTrait, InterestRateConfig,
            PragmaOracleParams, LiquidationParams, ShutdownParams, FeeParams, LiquidationConfig, ShutdownConfig
        },
        vendor::{
            erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait},
            ownable::{IOwnableTwoStepDispatcher, IOwnableTwoStepDispatcherTrait},
        },
        test::{
            setup_v2::{
                setup, setup_env, create_pool, TestConfig, deploy_assets, deploy_asset, COLL_PRAGMA_KEY,
                deploy_asset_with_decimals, test_interest_rate_config, LendingTerms, Env
            },
            mock_singleton_upgrade::{IMockSingletonUpgradeDispatcher, IMockSingletonUpgradeDispatcherTrait},
        },
    };

    #[test]
    fn test_pool_id() {
        let Env { singleton, extension, config, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        let pool_id = singleton.create_pool(array![].span(), array![].span(), extension.contract_address);
        stop_prank(CheatTarget::One(singleton.contract_address));

        assert!(pool_id == config.pool_id, "Invalid pool id");
    }

    #[test]
    #[should_panic(expected: "extension-is-zero")]
    fn test_create_pool_no_extension() {
        let Env { singleton, .. } = setup_env(Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero());
        singleton.create_pool(array![].span(), array![].span(), Zeroable::zero());
    }

    #[test]
    #[should_panic(expected: "asset-config-already-exists")]
    fn test_create_pool_duplicate_asset() {
        let Env { singleton, extension, config, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        // create ltv config for collateral and borrow assets
        let max_position_ltv_params_0 = LTVParams {
            collateral_asset_index: 1, debt_asset_index: 0, max_ltv: (80 * PERCENT).try_into().unwrap()
        };
        let max_position_ltv_params_1 = LTVParams {
            collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap()
        };

        let asset_params = array![collateral_asset_params, collateral_asset_params].span();
        let max_position_ltv_params = array![max_position_ltv_params_0, max_position_ltv_params_1].span();

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.create_pool(asset_params, max_position_ltv_params, extension.contract_address);
        stop_prank(CheatTarget::One(singleton.contract_address));
    }

    #[test]
    #[should_panic(expected: "invalid-ltv-config")]
    fn test_create_pool_assert_ltv_config_invalid_ltv_config() {
        let Env { singleton, extension, config, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        let collateral_asset = deploy_asset(
            ContractClass { class_hash: get_class_hash(config.collateral_asset.contract_address) },
            get_contract_address()
        );

        let collateral_asset_params = AssetParams {
            asset: collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        let debt_asset = deploy_asset(
            ContractClass { class_hash: get_class_hash(config.collateral_asset.contract_address) },
            get_contract_address()
        );

        let debt_asset_params = AssetParams {
            asset: debt_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        // create ltv config for collateral and borrow assets
        let max_position_ltv_params_0 = LTVParams {
            collateral_asset_index: 1, debt_asset_index: 0, max_ltv: 1_000_000_000_000_000_001
        };
        let max_position_ltv_params_1 = LTVParams {
            collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap()
        };

        let asset_params = array![collateral_asset_params, debt_asset_params].span();
        let max_position_ltv_params = array![max_position_ltv_params_0, max_position_ltv_params_1].span();

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.create_pool(asset_params, max_position_ltv_params, extension.contract_address);
        stop_prank(CheatTarget::One(singleton.contract_address));
    }

    #[test]
    #[should_panic(expected: "scale-exceeded")]
    fn test_create_pool_assert_asset_config_scale_exceeded() {
        let Env { singleton, extension, config, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        let asset = deploy_asset_with_decimals(
            ContractClass { class_hash: get_class_hash(config.collateral_asset.contract_address) },
            get_contract_address(),
            19
        );

        let collateral_asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        // create ltv config for collateral and borrow assets
        let max_position_ltv_params_0 = LTVParams {
            collateral_asset_index: 1, debt_asset_index: 0, max_ltv: (80 * PERCENT).try_into().unwrap()
        };
        let max_position_ltv_params_1 = LTVParams {
            collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap()
        };

        let asset_params = array![collateral_asset_params, collateral_asset_params].span();
        let max_position_ltv_params = array![max_position_ltv_params_0, max_position_ltv_params_1].span();

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.create_pool(asset_params, max_position_ltv_params, extension.contract_address);
        stop_prank(CheatTarget::One(singleton.contract_address));
    }

    #[test]
    #[should_panic(expected: "max-utilization-exceeded")]
    fn test_create_pool_assert_asset_config_max_utilization_exceeded() {
        let Env { singleton, extension, config, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE + 1,
            is_legacy: false,
            fee_rate: 0
        };

        // create ltv config for collateral and borrow assets
        let max_position_ltv_params_0 = LTVParams {
            collateral_asset_index: 1, debt_asset_index: 0, max_ltv: (80 * PERCENT).try_into().unwrap()
        };
        let max_position_ltv_params_1 = LTVParams {
            collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap()
        };

        let asset_params = array![collateral_asset_params, collateral_asset_params].span();
        let max_position_ltv_params = array![max_position_ltv_params_0, max_position_ltv_params_1].span();

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.create_pool(asset_params, max_position_ltv_params, extension.contract_address);
        stop_prank(CheatTarget::One(singleton.contract_address));
    }

    #[test]
    #[should_panic(expected: "rate-accumulator-too-low")]
    fn test_create_pool_assert_asset_config_rate_accumulator_too_low() {
        let Env { singleton, extension, config, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: 1,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0
        };

        // create ltv config for collateral and borrow assets
        let max_position_ltv_params_0 = LTVParams {
            collateral_asset_index: 1, debt_asset_index: 0, max_ltv: (80 * PERCENT).try_into().unwrap()
        };
        let max_position_ltv_params_1 = LTVParams {
            collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap()
        };

        let asset_params = array![collateral_asset_params, collateral_asset_params].span();
        let max_position_ltv_params = array![max_position_ltv_params_0, max_position_ltv_params_1].span();

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.create_pool(asset_params, max_position_ltv_params, extension.contract_address);
        stop_prank(CheatTarget::One(singleton.contract_address));
    }

    #[test]
    #[should_panic(expected: "fee-rate-exceeded")]
    fn test_create_pool_assert_asset_config_fee_rate_exceeded() {
        let Env { singleton, extension, config, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: SCALE + 1
        };

        // create ltv config for collateral and borrow assets
        let max_position_ltv_params_0 = LTVParams {
            collateral_asset_index: 1, debt_asset_index: 0, max_ltv: (80 * PERCENT).try_into().unwrap()
        };
        let max_position_ltv_params_1 = LTVParams {
            collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap()
        };

        let asset_params = array![collateral_asset_params, collateral_asset_params].span();
        let max_position_ltv_params = array![max_position_ltv_params_0, max_position_ltv_params_1].span();

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.create_pool(asset_params, max_position_ltv_params, extension.contract_address);
        stop_prank(CheatTarget::One(singleton.contract_address));
    }

    #[test]
    #[should_panic(expected: "caller-not-extension")]
    fn test_set_asset_config_not_extension() {
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

        singleton.set_asset_config(config.pool_id, asset_params);
    }

    #[test]
    fn test_set_asset_config() {
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
        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.set_asset_config(config.pool_id, asset_params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (asset_config, _) = singleton.asset_config(config.pool_id, config.collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
    }

    #[test]
    #[should_panic(expected: "caller-not-extension")]
    fn test_set_asset_parameter_not_extension() {
        let Env { singleton, extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        singleton.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'max_utilization', 0);
    }

    #[test]
    fn test_set_asset_parameter() {
        let Env { singleton, extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'max_utilization', 0);
        stop_prank(CheatTarget::One(singleton.contract_address));

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'floor', SCALE);
        stop_prank(CheatTarget::One(singleton.contract_address));

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.set_asset_parameter(config.pool_id, config.collateral_asset.contract_address, 'fee_rate', SCALE);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (asset_config, _) = singleton.asset_config_unsafe(config.pool_id, config.collateral_asset.contract_address);
        assert!(asset_config.max_utilization == 0, "Max utilization not set");
        assert!(asset_config.floor == SCALE, "Floor not set");
        assert!(asset_config.fee_rate == SCALE, "Fee rate not set");
    }

    #[test]
    fn test_set_asset_parameter_fee_shares() {
        let (singleton, extension, config, users, terms) = setup();
        let TestConfig { pool_id, collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, collateral_to_deposit, nominal_debt_to_draw, .. } = terms;

        assert!(singleton.extension(pool_id).is_non_zero(), "Pool not created");

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.set_asset_parameter(pool_id, debt_asset.contract_address, 'fee_rate', 10 * PERCENT);
        stop_prank(CheatTarget::One(singleton.contract_address));

        // LENDER

        // deposit collateral which is later borrowed by the borrower
        let params = ModifyPositionParams {
            pool_id,
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: liquidity_to_deposit.into(),
            },
            debt: Default::default(),
            data: ArrayTrait::new().span()
        };

        start_prank(CheatTarget::One(singleton.contract_address), users.lender);
        singleton.modify_position(params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        // BORROWER

        // deposit collateral and debt assets
        let params = ModifyPositionParams {
            pool_id,
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount {
                amount_type: AmountType::Target,
                denomination: AmountDenomination::Assets,
                value: collateral_to_deposit.into(),
            },
            debt: Amount {
                amount_type: AmountType::Target,
                denomination: AmountDenomination::Native,
                value: nominal_debt_to_draw.into(),
            },
            data: ArrayTrait::new().span()
        };

        start_prank(CheatTarget::One(singleton.contract_address), users.borrower);
        singleton.modify_position(params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        // interest accrued should be reflected since time has passed
        start_warp(CheatTarget::All, get_block_timestamp() + DAY_IN_SECONDS);

        let (position, _, _) = singleton
            .position(pool_id, debt_asset.contract_address, Zeroable::zero(), extension.contract_address);
        assert!(position.collateral_shares == 0, "No fee shares should not have accrued");

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton.set_asset_parameter(config.pool_id, debt_asset.contract_address, 'fee_rate', SCALE);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (position, _, _) = singleton
            .position(pool_id, debt_asset.contract_address, Zeroable::zero(), extension.contract_address);
        assert!(position.collateral_shares != 0, "Fee shares should have been accrued");

        let (asset_config, _) = singleton.asset_config_unsafe(config.pool_id, debt_asset.contract_address);
        assert!(asset_config.fee_rate == SCALE, "Fee rate not set");
    }

    #[test]
    fn test_set_ltv_config() {
        let Env { singleton, extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        create_pool(extension, config, users.creator, Option::None);

        start_prank(CheatTarget::One(singleton.contract_address), extension.contract_address);
        singleton
            .set_ltv_config(
                config.pool_id,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: (40 * PERCENT).try_into().unwrap() }
            );
        stop_prank(CheatTarget::One(singleton.contract_address));
    }

    #[test]
    #[should_panic(expected: "caller-not-extension")]
    fn test_set_extension_not_extension() {
        let Env { singleton, extension, config, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );

        let new_extension = contract_address_const::<'new_extension'>();

        create_pool(extension, config, users.creator, Option::None);

        singleton.set_extension_whitelist(new_extension, true);

        singleton.set_extension(config.pool_id, new_extension);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_singleton_upgrade_only_owner() {
        let Env { singleton, .. } = setup_env(Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero());
        let new_classhash = declare("MockSingletonUpgrade").class_hash;
        start_prank(CheatTarget::One(singleton.contract_address), contract_address_const::<'not_owner'>());
        singleton.upgrade(new_classhash);
    }

    #[test]
    fn test_singleton_upgrade() {
        let Env { singleton, .. } = setup_env(Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero());
        let new_classhash = declare("MockSingletonUpgrade").class_hash;
        singleton.upgrade(new_classhash);
        let tag = IMockSingletonUpgradeDispatcher { contract_address: singleton.contract_address }.tag();
        assert!(tag == 'MockSingletonUpgrade', "Invalid tag");
    }

    #[test]
    #[should_panic(expected: ('invalid upgrade name',))]
    fn test_singleton_upgrade_wrong_name() {
        let Env { singleton, .. } = setup_env(Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero());
        let new_classhash = declare("MockSingletonUpgradeWrongName").class_hash;
        singleton.upgrade(new_classhash);
    }

    #[test]
    fn test_singleton_change_owner() {
        let Env { singleton, users, .. } = setup_env(
            Zeroable::zero(), Zeroable::zero(), Zeroable::zero(), Zeroable::zero()
        );
        let ownable_dispatcher = IOwnableTwoStepDispatcher { contract_address: singleton.contract_address };

        assert!(ownable_dispatcher.owner() == users.owner, "Owner is not the contract address");

        let new_owner = contract_address_const::<'new_owner'>();
        ownable_dispatcher.transfer_ownership(new_owner);
        assert!(ownable_dispatcher.owner() == users.owner, "Invalid owner");
        assert!(ownable_dispatcher.pending_owner() == new_owner, "Invalid pending owner");

        start_prank(CheatTarget::One(singleton.contract_address), new_owner);
        ownable_dispatcher.accept_ownership();
        stop_prank(CheatTarget::One(singleton.contract_address));

        assert!(ownable_dispatcher.owner() == new_owner, "Invalid owner");
        assert!(ownable_dispatcher.pending_owner() == Zeroable::zero(), "Invalid pending owner");
    }
}
