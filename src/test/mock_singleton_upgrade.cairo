#[starknet::interface]
pub trait IMockSingletonUpgrade<TContractState> {
    fn upgrade_name(ref self: TContractState) -> felt252;
    fn tag(ref self: TContractState) -> felt252;
    fn pool_name(ref self: TContractState) -> felt252;
}

#[starknet::contract]
mod MockSingletonUpgrade {
    use starknet::storage::StoragePointerReadAccess;
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {
        pool_name: felt252,
    }

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu Singleton'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockSingletonUpgrade'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            self.pool_name.read()
        }
    }
}


#[starknet::contract]
mod MockPOV2Upgrade {
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu default po v2'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockPOV2Upgrade'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockEKV2Upgrade {
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu DefaultEKV2'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockEKV2Upgrade'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockSingletonUpgradeWrongName {
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Not Vesu'
        }
        fn tag(ref self: ContractState) -> felt252 {
            'MockSingletonUpgradeWrongName'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockEIC {
    use starknet::storage::StoragePointerWriteAccess;
    use vesu::singleton_v2::IEIC;

    #[storage]
    struct Storage {
        // used to check if the eic is initialized
        pool_name: felt252,
    }

    #[abi(embed_v0)]
    impl MockEICImpl of IEIC<ContractState> {
        fn eic_initialize(ref self: ContractState, data: Span<felt252>) {
            let mock_eic_param: felt252 = (*data[0]).try_into().unwrap();
            assert(mock_eic_param == 'NewPoolName', 'Invalid mock eic data');
            self.pool_name.write(mock_eic_param);
        }
    }
}
