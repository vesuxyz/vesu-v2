#[starknet::interface]
pub trait IMockPoolUpgrade<TContractState> {
    fn upgrade_name(ref self: TContractState) -> felt252;
    fn tag(ref self: TContractState) -> felt252;
    fn pool_name(ref self: TContractState) -> felt252;
}

#[starknet::contract]
mod MockPoolUpgrade {
    use starknet::storage::StoragePointerReadAccess;
    use vesu::test::mock_pool_upgrade::IMockPoolUpgrade;

    #[storage]
    struct Storage {
        pool_name: felt252,
    }

    #[abi(embed_v0)]
    impl MockPoolUpgradeImpl of IMockPoolUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu Pool'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockPoolUpgrade'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            self.pool_name.read()
        }
    }
}


#[starknet::contract]
mod MockExtensionPOV2Upgrade {
    use vesu::test::mock_pool_upgrade::IMockPoolUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockPoolUpgradeImpl of IMockPoolUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu default extension po v2'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockExtensionPOV2Upgrade'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockExtensionEKV2Upgrade {
    use vesu::test::mock_pool_upgrade::IMockPoolUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockPoolUpgradeImpl of IMockPoolUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu DefaultExtensionEKV2'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockExtensionEKV2Upgrade'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockPoolUpgradeWrongName {
    use vesu::test::mock_pool_upgrade::IMockPoolUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockPoolUpgradeImpl of IMockPoolUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Not Vesu'
        }
        fn tag(ref self: ContractState) -> felt252 {
            'MockPoolUpgradeWrongName'
        }

        fn pool_name(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockEIC {
    use starknet::storage::StoragePointerWriteAccess;
    use vesu::pool::IEIC;

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
