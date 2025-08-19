#[cfg(test)]
mod TestSingletonV2 {
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::interface::{IOwnableTwoStepDispatcher, IOwnableTwoStepDispatcherTrait};
    use openzeppelin::token::erc20::ERC20ABIDispatcherTrait;
    use snforge_std::{
        CheatSpan, DeclareResultTrait, cheat_caller_address, declare, start_cheat_block_timestamp_global,
        start_cheat_caller_address, stop_cheat_caller_address,
    };
    #[feature("deprecated-starknet-consts")]
    use starknet::{contract_address_const, get_block_timestamp, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, AssetParams, LTVConfig, LTVParams, ModifyPositionParams};
    use vesu::extension::components::interest_rate_model::InterestRateConfig;
    use vesu::extension::components::pragma_oracle::OracleConfig;
    use vesu::oracle::IOracleDispatcherTrait;
    use vesu::singleton_v2::ISingletonV2DispatcherTrait;
    use vesu::test::mock_singleton_upgrade::{IMockSingletonUpgradeDispatcher, IMockSingletonUpgradeDispatcherTrait};
    use vesu::test::setup_v2::{
        Env, LendingTerms, TestConfig, create_pool, deploy_asset, deploy_asset_with_decimals, setup, setup_env,
    };
    use vesu::units::{DAY_IN_SECONDS, INFLATION_FEE, PERCENT, SCALE};
    use vesu::vendor::pragma::AggregationMode;

    fn dummy_oracle_config() -> OracleConfig {
        OracleConfig {
            pragma_key: 1,
            timeout: 1,
            number_of_sources: 2,
            start_time_offset: 0,
            time_window: 0,
            aggregation_mode: AggregationMode::Median(()),
        }
    }

    fn dummy_interest_rate_config() -> InterestRateConfig {
        InterestRateConfig {
            min_target_utilization: 75_000,
            max_target_utilization: 85_000,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        }
    }

    #[test]
    #[should_panic(expected: "asset-config-nonexistent")]
    fn test_non_existent_asset_config() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(oracle, singleton, config, users.owner, users.extension_owner, Option::None);

        let dummy_address = contract_address_const::<'dummy'>();
        singleton.asset_config(dummy_address);
    }

    #[test]
    #[should_panic(expected: "asset-config-already-exists")]
    fn test_create_pool_duplicate_asset() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        // store all asset configurations
        let oracle_config = dummy_oracle_config();
        let interest_rate_config = dummy_interest_rate_config();
        cheat_caller_address(oracle.contract_address, users.owner, CheatSpan::TargetCalls(1));
        oracle.set_oracle_config(asset: collateral_asset_params.asset, :oracle_config);

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton.add_asset(params: collateral_asset_params, :interest_rate_config);
        singleton.add_asset(params: collateral_asset_params, :interest_rate_config);
        stop_cheat_caller_address(singleton.contract_address);
    }

    #[test]
    #[should_panic(expected: "invalid-ltv-config")]
    fn test_create_pool_assert_ltv_config_invalid_ltv_config() {
        let Env { oracle, singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let collateral_asset = deploy_asset(users.extension_owner);

        let collateral_asset_params = AssetParams {
            asset: collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        let debt_asset = deploy_asset(users.extension_owner);

        let debt_asset_params = AssetParams {
            asset: debt_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        // create ltv config for collateral and borrow assets
        let max_position_ltv_params_0 = LTVParams {
            collateral_asset_index: 1, debt_asset_index: 0, max_ltv: 1_000_000_000_000_000_001,
        };
        let max_position_ltv_params_1 = LTVParams {
            collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap(),
        };

        // store all asset configurations
        let oracle_config = dummy_oracle_config();
        let interest_rate_config = dummy_interest_rate_config();
        cheat_caller_address(collateral_asset.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        collateral_asset.approve(singleton.contract_address, INFLATION_FEE);
        cheat_caller_address(debt_asset.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        debt_asset.approve(singleton.contract_address, INFLATION_FEE);

        start_cheat_caller_address(oracle.contract_address, users.owner);
        oracle.set_oracle_config(asset: collateral_asset_params.asset, :oracle_config);

        oracle.set_oracle_config(asset: debt_asset_params.asset, :oracle_config);
        stop_cheat_caller_address(oracle.contract_address);

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton.add_asset(params: collateral_asset_params, :interest_rate_config);
        singleton.add_asset(params: debt_asset_params, :interest_rate_config);
        stop_cheat_caller_address(singleton.contract_address);

        // store all loan-to-value configurations for each asset pair
        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton
            .set_ltv_config(
                collateral_asset_params.asset,
                debt_asset_params.asset,
                LTVConfig { max_ltv: max_position_ltv_params_0.max_ltv },
            );

        singleton
            .set_ltv_config(
                collateral_asset_params.asset,
                debt_asset_params.asset,
                LTVConfig { max_ltv: max_position_ltv_params_1.max_ltv },
            );
        stop_cheat_caller_address(singleton.contract_address);
    }

    #[test]
    #[should_panic(expected: "scale-exceeded")]
    fn test_create_pool_assert_asset_config_scale_exceeded() {
        let Env { oracle, singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let asset = deploy_asset_with_decimals(get_contract_address(), 19);

        let collateral_asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        // store all asset configurations
        let interest_rate_config = dummy_interest_rate_config();
        let oracle_config = dummy_oracle_config();

        cheat_caller_address(oracle.contract_address, users.owner, CheatSpan::TargetCalls(1));
        oracle.set_oracle_config(asset: collateral_asset_params.asset, :oracle_config);

        cheat_caller_address(singleton.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        singleton.add_asset(params: collateral_asset_params, :interest_rate_config);
    }

    #[test]
    #[should_panic(expected: "max-utilization-exceeded")]
    fn test_create_pool_assert_asset_config_max_utilization_exceeded() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE + 1,
            is_legacy: false,
            fee_rate: 0,
        };

        // store all asset configurations
        let interest_rate_config = dummy_interest_rate_config();
        let oracle_config = dummy_oracle_config();

        cheat_caller_address(oracle.contract_address, users.owner, CheatSpan::TargetCalls(1));
        oracle.set_oracle_config(asset: collateral_asset_params.asset, :oracle_config);

        cheat_caller_address(singleton.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        singleton.add_asset(params: collateral_asset_params, :interest_rate_config);
    }

    #[test]
    #[should_panic(expected: "rate-accumulator-too-low")]
    fn test_create_pool_assert_asset_config_rate_accumulator_too_low() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: 1,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        // store all asset configurations
        let interest_rate_config = dummy_interest_rate_config();
        let oracle_config = dummy_oracle_config();

        cheat_caller_address(oracle.contract_address, users.owner, CheatSpan::TargetCalls(1));
        oracle.set_oracle_config(asset: collateral_asset_params.asset, :oracle_config);

        cheat_caller_address(singleton.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        singleton.add_asset(params: collateral_asset_params, :interest_rate_config);
    }

    #[test]
    #[should_panic(expected: "fee-rate-exceeded")]
    fn test_create_pool_assert_asset_config_fee_rate_exceeded() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let collateral_asset_params = AssetParams {
            asset: config.collateral_asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: SCALE + 1,
        };

        // store all asset configurations
        let interest_rate_config = dummy_interest_rate_config();
        let oracle_config = dummy_oracle_config();

        cheat_caller_address(oracle.contract_address, users.owner, CheatSpan::TargetCalls(1));
        oracle.set_oracle_config(asset: collateral_asset_params.asset, :oracle_config);

        cheat_caller_address(singleton.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        singleton.add_asset(params: collateral_asset_params, :interest_rate_config);
    }

    #[test]
    #[should_panic(expected: "caller-not-extension-owner")]
    fn test_add_asset_not_extension_owner() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(oracle, singleton, config, users.owner, users.extension_owner, Option::None);

        let asset = deploy_asset(users.extension_owner);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };

        let interest_rate_config = dummy_interest_rate_config();
        singleton.add_asset(asset_params, :interest_rate_config);
    }

    #[test]
    fn test_add_asset() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(oracle, singleton, config, users.owner, users.extension_owner, Option::None);

        let asset = deploy_asset(users.extension_owner);

        let asset_params = AssetParams {
            asset: asset.contract_address,
            floor: SCALE / 10_000,
            initial_rate_accumulator: SCALE,
            initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
            max_utilization: SCALE,
            is_legacy: false,
            fee_rate: 0,
        };
        cheat_caller_address(asset.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        asset.approve(singleton.contract_address, INFLATION_FEE);

        let oracle_config = dummy_oracle_config();
        let interest_rate_config = dummy_interest_rate_config();

        cheat_caller_address(oracle.contract_address, users.owner, CheatSpan::TargetCalls(1));
        oracle.set_oracle_config(asset: asset_params.asset, :oracle_config);

        cheat_caller_address(singleton.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        singleton.add_asset(asset_params, :interest_rate_config);

        let asset_config = singleton.asset_config(config.collateral_asset.contract_address);
        assert!(asset_config.floor != 0, "Asset config not set");
        assert!(asset_config.scale == config.collateral_scale, "Invalid scale");
        assert!(asset_config.last_rate_accumulator >= SCALE, "Last rate accumulator too low");
        assert!(asset_config.last_rate_accumulator < 10 * SCALE, "Last rate accumulator too high");
    }

    #[test]
    fn test_set_asset_parameter() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(oracle, singleton, config, users.owner, users.extension_owner, Option::None);

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton.set_asset_parameter(config.collateral_asset.contract_address, 'max_utilization', 0);
        stop_cheat_caller_address(singleton.contract_address);

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton.set_asset_parameter(config.collateral_asset.contract_address, 'floor', SCALE);
        stop_cheat_caller_address(singleton.contract_address);

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton.set_asset_parameter(config.collateral_asset.contract_address, 'fee_rate', SCALE);
        stop_cheat_caller_address(singleton.contract_address);

        let asset_config = singleton.asset_config(config.collateral_asset.contract_address);
        assert!(asset_config.max_utilization == 0, "Max utilization not set");
        assert!(asset_config.floor == SCALE, "Floor not set");
        assert!(asset_config.fee_rate == SCALE, "Fee rate not set");
    }

    #[test]
    fn test_set_asset_parameter_fee_shares() {
        let (_, singleton, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, collateral_to_deposit, nominal_debt_to_draw, .. } = terms;

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton.set_asset_parameter(debt_asset.contract_address, 'fee_rate', 10 * PERCENT);
        stop_cheat_caller_address(singleton.contract_address);

        // LENDER

        // deposit collateral which is later borrowed by the borrower
        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: liquidity_to_deposit.into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(singleton.contract_address, users.lender);
        singleton.modify_position(params);
        stop_cheat_caller_address(singleton.contract_address);

        // BORROWER

        // deposit collateral and debt assets
        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: nominal_debt_to_draw.into() },
        };

        start_cheat_caller_address(singleton.contract_address, users.borrower);
        singleton.modify_position(params);
        stop_cheat_caller_address(singleton.contract_address);

        let (fee_shares, _) = singleton.get_fees(debt_asset.contract_address);
        assert!(fee_shares == 0, "No fee shares should not have accrued");

        // interest accrued should be reflected since time has passed
        start_cheat_block_timestamp_global(get_block_timestamp() + DAY_IN_SECONDS);

        let (fee_shares_before, _) = singleton.get_fees(debt_asset.contract_address);

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton.set_asset_parameter(debt_asset.contract_address, 'fee_rate', SCALE);
        stop_cheat_caller_address(singleton.contract_address);

        let (fee_shares_after, _) = singleton.get_fees(debt_asset.contract_address);
        assert!(fee_shares_after == fee_shares_before, "Fee shares mismatch");

        let asset_config = singleton.asset_config(debt_asset.contract_address);
        assert!(asset_config.fee_rate == SCALE, "Fee rate not set");
    }

    #[test]
    fn test_set_ltv_config() {
        let Env {
            oracle, singleton, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        create_pool(oracle, singleton, config, users.owner, users.extension_owner, Option::None);

        start_cheat_caller_address(singleton.contract_address, users.extension_owner);
        singleton
            .set_ltv_config(
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                LTVConfig { max_ltv: (40 * PERCENT).try_into().unwrap() },
            );
        stop_cheat_caller_address(singleton.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_singleton_upgrade_only_owner() {
        let Env { singleton, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockSingletonUpgrade").unwrap().contract_class().class_hash;
        start_cheat_caller_address(singleton.contract_address, contract_address_const::<'not_owner'>());
        singleton.upgrade(new_classhash, Option::None);
    }

    #[test]
    fn test_singleton_upgrade() {
        let Env { singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockSingletonUpgrade").unwrap().contract_class().class_hash;
        cheat_caller_address(singleton.contract_address, users.owner, CheatSpan::TargetCalls(1));
        singleton.upgrade(new_classhash, Option::None);
        let tag = IMockSingletonUpgradeDispatcher { contract_address: singleton.contract_address }.tag();
        assert!(tag == 'MockSingletonUpgrade', "Invalid tag");
    }

    #[test]
    #[should_panic(expected: ('invalid upgrade name',))]
    fn test_singleton_upgrade_wrong_name() {
        let Env { singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockSingletonUpgradeWrongName").unwrap().contract_class().class_hash;
        cheat_caller_address(singleton.contract_address, users.owner, CheatSpan::TargetCalls(1));
        singleton.upgrade(new_classhash, Option::None);
    }

    #[test]
    fn test_singleton_upgrade_eic() {
        let Env { singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockSingletonUpgrade").unwrap().contract_class().class_hash;
        let eic_classhash = *declare("MockEIC").unwrap().contract_class().class_hash;
        let old_pool_name = 'PoolName';
        assert!(singleton.pool_name() == old_pool_name, "Old pool name mismatch");
        let new_pool_name = 'NewPoolName';
        cheat_caller_address(singleton.contract_address, users.owner, CheatSpan::TargetCalls(1));
        singleton.upgrade(new_classhash, Some((eic_classhash, array![new_pool_name].span())));
        let actual_new_pool_name = singleton.pool_name();
        assert!(actual_new_pool_name == new_pool_name, "New pool name mismatch");
    }

    #[test]
    #[should_panic(expected: 'Index out of bounds')]
    fn test_singleton_upgrade_eic_initialize_failed() {
        let Env { singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockSingletonUpgrade").unwrap().contract_class().class_hash;
        let eic_classhash = *declare("MockEIC").unwrap().contract_class().class_hash;
        cheat_caller_address(singleton.contract_address, users.owner, CheatSpan::TargetCalls(1));
        singleton.upgrade(new_classhash, Some((eic_classhash, array![].span())));
    }

    #[test]
    #[should_panic(expected: 'Invalid mock eic data')]
    fn test_singleton_upgrade_eic_invalid_data() {
        let Env { singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockSingletonUpgrade").unwrap().contract_class().class_hash;
        let eic_classhash = *declare("MockEIC").unwrap().contract_class().class_hash;
        cheat_caller_address(singleton.contract_address, users.owner, CheatSpan::TargetCalls(1));
        singleton.upgrade(new_classhash, Some((eic_classhash, array!['invalid-mock-eic-data'].span())));
    }

    #[test]
    fn test_singleton_change_owner() {
        let Env { singleton, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let ownable_dispatcher = IOwnableTwoStepDispatcher { contract_address: singleton.contract_address };

        assert!(ownable_dispatcher.owner() == users.owner, "Owner is not the contract address");

        let new_owner = contract_address_const::<'new_owner'>();
        cheat_caller_address(singleton.contract_address, users.owner, CheatSpan::TargetCalls(1));
        ownable_dispatcher.transfer_ownership(new_owner);
        assert!(ownable_dispatcher.owner() == users.owner, "Invalid owner");
        assert!(ownable_dispatcher.pending_owner() == new_owner, "Invalid pending owner");

        start_cheat_caller_address(singleton.contract_address, new_owner);
        ownable_dispatcher.accept_ownership();
        stop_cheat_caller_address(singleton.contract_address);

        assert!(ownable_dispatcher.owner() == new_owner, "Invalid owner");
        assert!(ownable_dispatcher.pending_owner() == Zero::zero(), "Invalid pending owner");
    }
}
