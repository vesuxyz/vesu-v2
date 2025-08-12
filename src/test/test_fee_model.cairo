#[cfg(test)]
mod TestFeeModel {
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use snforge_std::{DeclareResultTrait, declare, replace_bytecode};
    #[feature("deprecated-starknet-consts")]
    use starknet::contract_address_const;
    use vesu::extension::default_extension_po_v2::{
        IDefaultExtensionPOV2Dispatcher, IDefaultExtensionPOV2DispatcherTrait,
    };
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};

    fn setup(pool_id: felt252) -> (ISingletonV2Dispatcher, IDefaultExtensionPOV2Dispatcher) {
        let singleton = ISingletonV2Dispatcher {
            contract_address: contract_address_const::<
                0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160,
            >(),
        };
        replace_bytecode(singleton.contract_address, *declare("SingletonV2").unwrap().contract_class().class_hash)
            .unwrap();

        let extension = IDefaultExtensionPOV2Dispatcher { contract_address: singleton.extension(pool_id) };
        replace_bytecode(
            extension.contract_address, *declare("DefaultExtensionPOV2").unwrap().contract_class().class_hash,
        )
            .unwrap();

        (singleton, extension)
    }

    #[test]
    #[fork("Mainnet")]
    fn test_claim_fees() {
        let pool_id = 0x6febb313566c48e30614ddab092856a9ab35b80f359868ca69b2649ca5d148d;
        let (singleton, extension) = setup(pool_id);
        let asset = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8 // USDC token.
            >(),
        };

        let fee_recipient = extension.fee_config(pool_id).fee_recipient;
        let initial_balance = asset.balance_of(fee_recipient);

        singleton.claim_fees(pool_id, asset.contract_address);

        let new_balance = asset.balance_of(fee_recipient);
        assert!(new_balance > initial_balance);
    }
}
