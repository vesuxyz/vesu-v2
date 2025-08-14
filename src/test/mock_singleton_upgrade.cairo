#[starknet::interface]
pub trait IMockSingletonUpgrade<TContractState> {
    fn upgrade_name(ref self: TContractState) -> felt252;
    fn tag(ref self: TContractState) -> felt252;
    fn mock_singleton_upgrade_getter(ref self: TContractState) -> felt252;
}

#[starknet::interface]
pub trait IEIC<TContractState> {
    fn initialize(ref self: TContractState, data: Span<felt252>);
}

#[starknet::contract]
mod MockSingletonUpgrade {
    use starknet::storage::StoragePointerReadAccess;
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {
        mock_singleton_upgrade_member: felt252,
    }

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu Singleton'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockSingletonUpgrade'
        }

        fn mock_singleton_upgrade_getter(ref self: ContractState) -> felt252 {
            self.mock_singleton_upgrade_member.read()
        }
    }
}


#[starknet::contract]
mod MockExtensionPOV2Upgrade {
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu default extension po v2'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockExtensionPOV2Upgrade'
        }

        fn mock_singleton_upgrade_getter(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockExtensionEKV2Upgrade {
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu DefaultExtensionEKV2'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockExtensionEKV2Upgrade'
        }

        fn mock_singleton_upgrade_getter(ref self: ContractState) -> felt252 {
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

        fn mock_singleton_upgrade_getter(ref self: ContractState) -> felt252 {
            'mock-default-value'
        }
    }
}

#[starknet::contract]
mod MockEIC {
    use starknet::storage::StoragePointerWriteAccess;
    use vesu::test::mock_singleton_upgrade::IEIC;

    #[storage]
    struct Storage {
        // used to check if the eic is initialized
        mock_singleton_upgrade_member: felt252,
    }

    #[abi(embed_v0)]
    impl MockEICImpl of IEIC<ContractState> {
        fn initialize(ref self: ContractState, mut data: Span<felt252>) {
            let mock_eic_param: felt252 = (*data[0]).try_into().unwrap();
            self.mock_singleton_upgrade_member.write(mock_eic_param);
        }
    }
}
