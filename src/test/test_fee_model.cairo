#[cfg(test)]
mod TestFeeModel {
    use snforge_std::{
        CheatSpan, CheatTarget, declare, get_class_hash, load, map_entry_address, prank, replace_bytecode, start_prank,
        start_warp, stop_prank, store,
    };
    use starknet::{ContractAddress, contract_address_const, get_block_timestamp, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, AmountType, AssetParams, ModifyPositionParams};
    use vesu::extension::components::interest_rate_model::InterestRateConfig;
    use vesu::extension::default_extension_po_v2::{
        IDefaultExtensionPOV2Dispatcher, IDefaultExtensionPOV2DispatcherTrait, PragmaOracleParams, VTokenParams,
    };
    use vesu::extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::test::test_forking::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};
    use vesu::units::SCALE;
    use vesu::vendor::erc20::{ERC20ABIDispatcher as IERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use vesu::vendor::pragma::AggregationMode;

    fn setup(pool_id: felt252) -> (ISingletonV2Dispatcher, IDefaultExtensionPOV2Dispatcher) {
        let singleton = ISingletonV2Dispatcher {
            contract_address: contract_address_const::<
                0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160,
            >(),
        };

        let extension = IDefaultExtensionPOV2Dispatcher { contract_address: singleton.extension(pool_id) };
        replace_bytecode(extension.contract_address, declare("DefaultExtensionPOV2").class_hash);

        (singleton, extension)
    }

    #[test]
    #[fork("Mainnet")]
    fn test_claim_fees() {
        let pool_id = 0x6febb313566c48e30614ddab092856a9ab35b80f359868ca69b2649ca5d148d;
        let (_, extension) = setup(pool_id);
        let asset = IERC20ABIDispatcher {
            contract_address: contract_address_const::<
                0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87,
            >(),
        };

        let owner = extension.pool_owner(pool_id);
        let fee_recipient = extension.fee_config(pool_id).fee_recipient;
        let initial_balance = asset.balance_of(fee_recipient);

        prank(CheatTarget::One(extension.contract_address), owner, CheatSpan::TargetCalls(1));
        extension.claim_fees(pool_id, asset.contract_address);

        assert!(asset.balance_of(fee_recipient) > initial_balance);
        assert!(asset.balance_of(fee_recipient) - initial_balance < SCALE);
    }
}
