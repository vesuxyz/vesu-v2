use starknet::ContractAddress;

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct FeeConfig {
    pub fee_recipient: ContractAddress,
}

#[starknet::component]
pub mod fee_model_component {
    use alexandria_math::i257::I257Trait;
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, AmountType, ModifyPositionParams, UpdatePositionResponse};
    use vesu::extension::components::fee_model::FeeConfig;
    use vesu::extension::default_extension_po_v2::IDefaultExtensionCallback;
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};


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

    #[derive(Drop, starknet::Event)]
    pub struct ClaimFees {
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        SetFeeConfig: SetFeeConfig,
        ClaimFees: ClaimFees,
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

        /// Claims the fees accrued in the extension for a given asset and sends them to the fee recipient
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        fn claim_fees(ref self: ComponentState<TContractState>, collateral_asset: ContractAddress) {
            let singleton = self.get_contract().singleton();

            let (position, _, _) = ISingletonV2Dispatcher { contract_address: singleton }
                .position(collateral_asset, Zero::zero(), get_contract_address());

            let amount = position.collateral_shares;

            let UpdatePositionResponse {
                collateral_delta, ..,
            } =
                ISingletonV2Dispatcher { contract_address: singleton }
                    .modify_position(
                        ModifyPositionParams {
                            collateral_asset,
                            debt_asset: Zero::zero(),
                            user: get_contract_address(),
                            collateral: Amount {
                                amount_type: AmountType::Delta,
                                denomination: AmountDenomination::Native,
                                value: I257Trait::new(amount, true),
                            },
                            debt: Default::default(),
                            data: ArrayTrait::new().span(),
                        },
                    );

            let fee_config = self.fee_config.read();
            let amount = collateral_delta.abs();

            IERC20Dispatcher { contract_address: collateral_asset }.transfer(fee_config.fee_recipient, amount);

            self
                .emit(
                    ClaimFees {
                        collateral_asset, debt_asset: Zero::zero(), recipient: fee_config.fee_recipient, amount,
                    },
                );
        }
    }
}
