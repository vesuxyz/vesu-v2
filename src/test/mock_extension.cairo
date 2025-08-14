#[starknet::contract]
mod MockExtension {
    use alexandria_math::i257::i257;
    use core::num::traits::Zero;
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::data_model::{Amount, AssetPrice, Context};
    use vesu::extension::interface::IExtension;
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::units::SCALE;

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

        fn price(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            ISingletonV2Dispatcher { contract_address: self.singleton.read() }
                .context(asset, Zero::zero(), Zero::zero());
            AssetPrice { value: SCALE, is_valid: true }
        }

        fn interest_rate(
            self: @ContractState,
            asset: ContractAddress,
            utilization: u256,
            last_updated: u64,
            last_full_utilization_rate: u256,
        ) -> u256 {
            ISingletonV2Dispatcher { contract_address: self.singleton.read() }
                .context(asset, Zero::zero(), Zero::zero());
            SCALE
        }

        fn rate_accumulator(
            self: @ContractState,
            asset: ContractAddress,
            utilization: u256,
            last_updated: u64,
            last_rate_accumulator: u256,
            last_full_utilization_rate: u256,
        ) -> (u256, u256) {
            ISingletonV2Dispatcher { contract_address: self.singleton.read() }.asset_config(asset);
            (SCALE, SCALE)
        }

        fn after_modify_position(
            ref self: ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            data: Span<felt252>,
            caller: ContractAddress,
        ) -> bool {
            true
        }

        fn before_liquidate_position(
            ref self: ContractState, context: Context, data: Span<felt252>, caller: ContractAddress,
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
            data: Span<felt252>,
            caller: ContractAddress,
        ) -> bool {
            true
        }
    }
}
