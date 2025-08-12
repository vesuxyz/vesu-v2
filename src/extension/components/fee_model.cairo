use starknet::ContractAddress;

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct FeeConfig {
    pub fee_recipient: ContractAddress,
}

#[starknet::component]
pub mod fee_model_component {
    use starknet::storage::StoragePointerWriteAccess;
    use vesu::extension::components::fee_model::FeeConfig;
    use vesu::extension::default_extension_po_v2::IDefaultExtensionCallback;

    #[storage]
    pub struct Storage {
        // fee configuration
        pub fee_config: FeeConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetFeeConfig {
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
        /// Sets the fee configuration
        /// # Arguments
        /// * `fee_config` - The fee configuration
        fn set_fee_config(ref self: ComponentState<TContractState>, fee_config: FeeConfig) {
            self.fee_config.write(fee_config);
            self.emit(SetFeeConfig { fee_config });
        }
    }
}
