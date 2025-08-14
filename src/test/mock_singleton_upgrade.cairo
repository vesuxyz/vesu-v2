#[starknet::interface]
pub trait IMockSingletonUpgrade<TContractState> {
    fn upgrade_name(ref self: TContractState) -> felt252;
    fn tag(ref self: TContractState) -> felt252;
}

#[starknet::interface]
pub trait IEIC<TContractState> {
    fn initialize(ref self: TContractState, data: Span<felt252>);
}

#[starknet::contract]
mod MockSingletonUpgrade {
    use vesu::test::mock_singleton_upgrade::IMockSingletonUpgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockSingletonUpgradeImpl of IMockSingletonUpgrade<ContractState> {
        fn upgrade_name(ref self: ContractState) -> felt252 {
            'Vesu Singleton'
        }

        fn tag(ref self: ContractState) -> felt252 {
            'MockSingletonUpgrade'
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
    }
}

#[starknet::contract]
mod MockEIC {
    use vesu::test::mock_singleton_upgrade::IEIC;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockEICImpl of IEIC<ContractState> {
        fn initialize(ref self: ContractState, mut data: Span<felt252>) {
            let deserialized: felt252 = (*data[0]).try_into().unwrap();
            assert!(deserialized == 'mock-eic-data', "invalid-eic-data");
        }
    }
}

#[starknet::contract]
mod MockEICFailure {
    use vesu::test::mock_singleton_upgrade::IEIC;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockEICImpl of IEIC<ContractState> {
        fn initialize(ref self: ContractState, mut data: Span<felt252>) {
            assert!(false, "eic-failure");
        }
    }
}
