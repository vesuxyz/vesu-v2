#[starknet::interface]
pub trait IMockPoolFactoryUpgrade<TContractState> {
    fn upgrade_name(ref self: TContractState) -> felt252;
    fn tag(ref self: TContractState) -> felt252;
    fn pool_class_hash(ref self: TContractState) -> felt252;
}

#[starknet::contract]
mod MockPoolFactoryUpgrade {
    use starknet::storage::StoragePointerReadAccess;
    use vesu::test::mock_pool_factory_upgrade::IMockPoolFactoryUpgrade;

    #[storage]
    struct Storage {
        pool_class_hash: felt252,
    }

    #[abi(embed_v0)]
    impl MockPoolFactoryUpgradeImpl of IMockPoolFactoryUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu Pool Factory'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockPoolFactoryUpgrade'
        }

        fn pool_class_hash(ref self: ContractState) -> felt252 {
            self.pool_class_hash.read()
        }
    }
}

#[starknet::contract]
mod MockPoolFactoryUpgradeWrongName {
    use vesu::test::mock_pool_factory_upgrade::IMockPoolFactoryUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockPoolFactoryUpgradeImpl of IMockPoolFactoryUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Not Vesu'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockPoolFactoryUpgradeWrongName'
        }

        fn pool_class_hash(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockEICFactory {
    use starknet::storage::StoragePointerWriteAccess;
    use vesu::pool::IEIC;

    #[storage]
    struct Storage {
        // used to check if the eic is initialized
        pool_class_hash: felt252,
    }

    #[abi(embed_v0)]
    impl MockEICImpl of IEIC<ContractState> {
        fn eic_initialize(ref self: ContractState, data: Span<felt252>) {
            let mock_eic_param: felt252 = (*data[0]).try_into().unwrap();
            assert(mock_eic_param == 'NewPoolClassHash', 'Invalid mock eic data');
            self.pool_class_hash.write(mock_eic_param);
        }
    }
}
