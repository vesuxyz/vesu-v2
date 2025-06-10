#[cfg(test)]
mod TestMigrationExtension {
    use snforge_std::{cheatcodes::{CheatTarget, start_prank, stop_prank, CheatSpan}, declare, prank};
    use starknet::{ContractAddress, get_contract_address, get_caller_address, contract_address_const};
    use vesu::{
        test::v2::setup_v2::{deploy_contract, deploy_with_args},
        v2::migration_extension::{IMigrationExtensionDispatcher, IMigrationExtensionDispatcherTrait}
    };

    fn deploy_migration_extension() -> ContractAddress {
        // let singleton = deploy_contract('Singleton');
        // let singleton_v2 = deploy_contract('SingletonV2');
        // let extension = deploy_contract('DefaultExtensionPO');
        // let extension_v2 = deploy_contract('DefaultExtensionPOV2');
        let migration_extension_calldata: Array<felt252> = array![get_caller_address().into()];
        deploy_with_args("MigrationExtension", migration_extension_calldata)
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_set_owner_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.set_owner(get_contract_address());
    }

    #[test]
    fn test_migration_set_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        start_prank(CheatTarget::One(migration_extension.contract_address), get_caller_address());
        migration_extension.set_owner(get_contract_address());
        assert(migration_extension.owner() == get_contract_address(), 'owner not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_set_singleton_v2_migrator_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.set_singleton_v2_migrator(get_contract_address());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_set_extension_v2_migrator_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.set_extension_v2_migrator(get_contract_address(), get_contract_address());
    }

    #[test]
    fn test_migration_set_contracts() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        start_prank(CheatTarget::One(migration_extension.contract_address), get_caller_address());
        migration_extension.set_contracts(get_contract_address(), get_contract_address());
        assert(migration_extension.singleton_v1() == get_contract_address(), 'singleton_v1 not set');
        assert(migration_extension.singleton_v2() == get_contract_address(), 'singleton_v2 not set');
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_set_contracts_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.set_contracts(get_contract_address(), get_contract_address());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_set_pool_owner_v1_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.set_pool_owner_v1(0x1234, get_contract_address(), get_contract_address());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_set_pool_owner_v2_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.set_pool_owner_v2(0x1234, get_contract_address(), get_contract_address());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_reset_extension_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.reset_extension(0x1234, get_contract_address());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_migrate_init_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.migrate_init(0x1234);
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_migrate_pool_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension
            .migrate_pool(0x1234, get_contract_address(), get_contract_address(), array![].span(), array![].span());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_migrate_pool_extension_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.migrate_pool_extension(0x1234, get_contract_address(), array![].span(), array![].span());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_migrate_extension_positions_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.migrate_extension_positions(0x1234, get_contract_address(), array![].span());
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_migrate_funds_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.migrate_funds(0x1234, array![].span(), 0);
    }

    #[test]
    #[should_panic(expected: "caller-not-owner")]
    fn test_migration_migrate_unlock_not_owner() {
        let migration_extension = IMigrationExtensionDispatcher { contract_address: deploy_migration_extension() };
        migration_extension.migrate_unlock();
    }
}
