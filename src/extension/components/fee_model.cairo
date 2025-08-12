use starknet::ContractAddress;

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct FeeConfig {
    pub fee_recipient: ContractAddress,
}

#[starknet::component]
pub mod fee_model_component {
    use starknet::storage::{Map, StorageMapWriteAccess};
    use vesu::extension::components::fee_model::FeeConfig;
    use vesu::extension::default_extension_po_v2::IDefaultExtensionCallback;

    #[storage]
    pub struct Storage {
        // pool_id -> fee configuration
        pub fee_configs: Map<felt252, FeeConfig>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetFeeConfig {
        #[key]
        pool_id: felt252,
        #[key]
        fee_config: FeeConfig,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        SetFeeConfig: SetFeeConfig,
    }

    #[generate_trait]
    pub impl FeeModelTrait<
        TContractState, +HasComponent<TContractState>, +IDefaultExtensionCallback<TContractState>,
    > of Trait<TContractState> {
        /// Sets the fee configuration for a pool
        /// # Arguments
        /// * `pool_id` - The pool id
        /// * `fee_config` - The fee configuration
        fn set_fee_config(ref self: ComponentState<TContractState>, pool_id: felt252, fee_config: FeeConfig) {
            self.fee_configs.write(pool_id, fee_config);
            self.emit(SetFeeConfig { pool_id, fee_config });
        }
    }
}
