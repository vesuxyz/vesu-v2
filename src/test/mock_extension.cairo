#[starknet::contract]
mod MockExtension {
    use alexandria_math::i257::i257;
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::data_model::Context;
    use vesu::extension::interface::IExtension;

    #[storage]
    struct Storage {
        singleton: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(ref self: ContractState, singleton: ContractAddress) {
        self.singleton.write(singleton);
    }

    #[abi(embed_v0)]
    impl MockExtensionImpl of IExtension<ContractState> {
        fn singleton(self: @ContractState) -> ContractAddress {
            self.singleton.read()
        }

        fn after_modify_position(
            ref self: ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            caller: ContractAddress,
        ) -> bool {
            true
        }

        fn before_liquidate_position(
            ref self: ContractState,
            context: Context,
            min_collateral_to_receive: u256,
            debt_to_repay: u256,
            caller: ContractAddress,
        ) -> (u256, u256, u256) {
            (Default::default(), Default::default(), Default::default())
        }

        fn after_liquidate_position(
            ref self: ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            bad_debt: u256,
            caller: ContractAddress,
        ) -> bool {
            true
        }
    }
}
