#[cfg(test)]
mod TestPoolFactory {
    use core::num::traits::{Bounded, Zero};
    use openzeppelin::token::erc20::ERC20ABIDispatcherTrait;
    use snforge_std::{CheatSpan, DeclareResultTrait, cheat_caller_address, declare, start_cheat_caller_address};
    #[feature("deprecated-starknet-consts")]
    use starknet::contract_address_const;
    use vesu::data_model::{AssetParams, VTokenParams};
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::oracle::{IPragmaOracleDispatcherTrait, OracleConfig};
    use vesu::pool::IPoolDispatcherTrait;
    use vesu::pool_factory::{IPoolFactoryDispatcherTrait, IPoolFactorySafeDispatcher, IPoolFactorySafeDispatcherTrait};
    use vesu::test::mock_oracle::{IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait};
    use vesu::test::mock_pool_factory_upgrade::{
        IMockPoolFactoryUpgradeDispatcher, IMockPoolFactoryUpgradeDispatcherTrait,
    };
    use vesu::test::setup_v2::{Env, create_pool_via_factory, deploy_asset, setup_env};
    use vesu::units::{PERCENT, SCALE, SCALE_128};
    use vesu::vendor::pragma::AggregationMode;

    #[test]
    fn test_pool_factory_set_pool_class_hash() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.set_pool_class_hash('NewPoolClassHash');
        assert!(pool_factory.pool_class_hash() == 'NewPoolClassHash');
    }

    #[test]
    #[should_panic(expected: 'Caller is not the owner')]
    fn test_pool_factory_set_pool_class_hash_not_owner() {
        let Env { pool_factory, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        pool_factory.set_pool_class_hash('NewPoolClassHash');
    }

    fn test_pool_factory_set_v_token_class_hash() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.set_v_token_class_hash('NewVTokenClassHash');
        assert!(pool_factory.v_token_class_hash() == 'NewVTokenClassHash');
    }

    #[test]
    #[should_panic(expected: 'Caller is not the owner')]
    fn test_pool_factory_set_v_token_class_hash_not_owner() {
        let Env { pool_factory, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        pool_factory.set_v_token_class_hash('NewVTokenClassHash');
    }

    #[test]
    fn test_pool_factory_set_oracle_class_hash() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.set_oracle_class_hash('NewOracleClassHash');
        assert!(pool_factory.oracle_class_hash() == 'NewOracleClassHash');
    }

    #[test]
    #[should_panic(expected: 'Caller is not the owner')]
    fn test_pool_factory_set_oracle_class_hash_not_owner() {
        let Env { pool_factory, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        pool_factory.set_oracle_class_hash('NewOracleClassHash');
    }

    #[test]
    fn test_pool_factory_create_pool() {
        let Env {
            pool_factory, oracle, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        create_pool_via_factory(pool_factory, oracle, config, users.owner, users.curator, Option::None);
    }

    #[test]
    fn test_pool_factory_add_asset() {
        let Env {
            pool_factory, oracle, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let pool = create_pool_via_factory(pool_factory, oracle, config, users.owner, users.curator, Option::None);

        let asset = deploy_asset(users.curator);
        cheat_caller_address(asset.contract_address, users.curator, CheatSpan::TargetCalls(1));
        asset.approve(pool_factory.contract_address, Bounded::<u256>::MAX);

        IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() }.set_price('Asset', SCALE_128);

        cheat_caller_address(oracle.contract_address, users.curator, CheatSpan::TargetCalls(1));
        oracle
            .add_asset(
                asset.contract_address,
                OracleConfig {
                    pragma_key: 'Asset',
                    timeout: 0,
                    number_of_sources: 2,
                    start_time_offset: 0,
                    time_window: 0,
                    aggregation_mode: AggregationMode::Median,
                },
            );

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
            max_target_utilization: 90_000,
            target_utilization: 87_500,
            min_full_utilization_rate: 1582470460,
            max_full_utilization_rate: 32150205761,
            zero_utilization_rate: 158247046,
            rate_half_life: 172_800,
            target_rate_percent: 20 * PERCENT,
        };

        let v_token_params = VTokenParams {
            v_token_name: "VToken", v_token_symbol: "VTK", debt_asset: config.debt_asset.contract_address,
        };

        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.accept_curator_ownership();

        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.nominate_curator(pool_factory.contract_address);

        #[feature("safe_dispatcher")]
        assert!(
            !IPoolFactorySafeDispatcher { contract_address: pool_factory.contract_address }
                .add_asset(
                    pool.contract_address,
                    asset.contract_address,
                    asset_params,
                    interest_rate_config,
                    v_token_params.clone(),
                )
                .is_ok(),
        );

        cheat_caller_address(pool_factory.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool_factory
            .add_asset(
                pool.contract_address,
                asset.contract_address,
                asset_params,
                interest_rate_config,
                v_token_params.clone(),
            );

        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.accept_curator_ownership();
        assert!(pool.curator() == users.curator);
    }

    #[test]
    fn test_pool_factory_create_oracle() {
        let Env { pool_factory, oracle, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());

        let oracle = pool_factory.create_oracle(users.owner, oracle.pragma_oracle(), oracle.pragma_summary());

        assert!(oracle != Zero::zero());
    }

    #[test]
    fn test_pool_factory_update_v_token() {
        let Env {
            pool_factory, oracle, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let pool = create_pool_via_factory(pool_factory, oracle, config, users.owner, users.curator, Option::None);

        cheat_caller_address(pool_factory.contract_address, pool.curator(), CheatSpan::TargetCalls(1));
        pool_factory
            .update_v_token(
                pool.contract_address,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                "VToken",
                "VTK",
            );
    }

    #[test]
    #[should_panic(expected: "caller-not-curator")]
    fn test_pool_factory_update_v_token_not_curator() {
        let Env {
            pool_factory, oracle, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let pool = create_pool_via_factory(pool_factory, oracle, config, users.owner, users.curator, Option::None);

        pool_factory
            .update_v_token(
                pool.contract_address,
                config.collateral_asset.contract_address,
                config.debt_asset.contract_address,
                "VToken",
                "VTK",
            );
    }

    #[test]
    #[should_panic(expected: ('Caller is not the owner',))]
    fn test_pool_factory_upgrade_only_owner() {
        let Env { pool_factory, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockPoolFactoryUpgrade").unwrap().contract_class().class_hash;
        start_cheat_caller_address(pool_factory.contract_address, contract_address_const::<'not_owner'>());
        pool_factory.upgrade(new_classhash, Option::None);
    }

    #[test]
    fn test_pool_factory_upgrade() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockPoolFactoryUpgrade").unwrap().contract_class().class_hash;
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.upgrade(new_classhash, Option::None);
        let tag = IMockPoolFactoryUpgradeDispatcher { contract_address: pool_factory.contract_address }.tag();
        assert!(tag == 'MockPoolFactoryUpgrade', "Invalid tag");
    }

    #[test]
    #[should_panic(expected: ('invalid upgrade name',))]
    fn test_pool_factory_upgrade_wrong_name() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockPoolFactoryUpgradeWrongName").unwrap().contract_class().class_hash;
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.upgrade(new_classhash, Option::None);
    }

    #[test]
    fn test_pool_factory_upgrade_eic() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockPoolFactoryUpgrade").unwrap().contract_class().class_hash;
        let eic_classhash = *declare("MockEICFactory").unwrap().contract_class().class_hash;
        let new_pool_class_hash = 'NewPoolClassHash';
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.upgrade(new_classhash, Some((eic_classhash, array![new_pool_class_hash].span())));
        let actual_new_pool_class_hash = pool_factory.pool_class_hash();
        assert!(actual_new_pool_class_hash == new_pool_class_hash, "New pool class hash mismatch");
    }

    #[test]
    #[should_panic(expected: 'Index out of bounds')]
    fn test_pool_factory_upgrade_eic_initialize_failed() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockPoolFactoryUpgrade").unwrap().contract_class().class_hash;
        let eic_classhash = *declare("MockEICFactory").unwrap().contract_class().class_hash;
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.upgrade(new_classhash, Some((eic_classhash, array![].span())));
    }

    #[test]
    #[should_panic(expected: 'Invalid mock eic data')]
    fn test_pool_factory_upgrade_eic_invalid_data() {
        let Env { pool_factory, users, .. } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        let new_classhash = *declare("MockPoolFactoryUpgrade").unwrap().contract_class().class_hash;
        let eic_classhash = *declare("MockEICFactory").unwrap().contract_class().class_hash;
        cheat_caller_address(pool_factory.contract_address, users.owner, CheatSpan::TargetCalls(1));
        pool_factory.upgrade(new_classhash, Some((eic_classhash, array!['invalid-mock-eic-data'].span())));
    }
}
