#[cfg(test)]
mod TestUpgrade {
    use snforge_std::{
        DeclareResultTrait, declare, get_class_hash, start_cheat_caller_address, stop_cheat_caller_address,
    };
    #[feature("deprecated-starknet-consts")]
    use starknet::contract_address_const;
    use vesu::extension::default_extension_po_v2::{
        IDefaultExtensionPOV2Dispatcher, IDefaultExtensionPOV2DispatcherTrait,
    };
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::vendor::ownable::{IOwnableDispatcher, IOwnableDispatcherTrait};

    fn setup(pool_id: felt252) -> (ISingletonV2Dispatcher, IDefaultExtensionPOV2Dispatcher) {
        let singleton = ISingletonV2Dispatcher {
            contract_address: contract_address_const::<
                0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160,
            >(),
        };
        let extension = IDefaultExtensionPOV2Dispatcher { contract_address: singleton.extension(pool_id) };
        (singleton, extension)
    }

    #[test]
    #[fork("Mainnet")]
    fn test_upgrade() {
        let pool_id = 0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28;
        let (singleton, extension) = setup(pool_id);

        let owner = IOwnableDispatcher { contract_address: singleton.contract_address }.owner();
        let extension_v1_class_hash = get_class_hash(extension.contract_address);
        let extension_v2_class_hash = *declare("DefaultExtensionPOV2").unwrap().contract_class().class_hash;

        start_cheat_caller_address(extension.contract_address, owner);

        let pool_ids = array![
            0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28 // 0x3de03fafe6120a3d21dc77e101de62e165b2cdfe84d12540853bd962b970f99,
            // 0x52fb52363939c3aa848f8f4ac28f0a51379f8d1b971d8444de25fbd77d8f161,
        // 0x2e06b705191dbe90a3fbaad18bb005587548048b725116bff3104ca501673c1,
        // 0x6febb313566c48e30614ddab092856a9ab35b80f359868ca69b2649ca5d148d,
        // 0x59ae5a41c9ae05eae8d136ad3d7dc48e5a0947c10942b00091aeb7f42efabb7,
        // 0x43f475012ed51ff6967041fcb9bf28672c96541ab161253fc26105f4c3b2afe,
        // 0x7bafdbd2939cc3f3526c587cb0092c0d9a93b07b9ced517873f7f6bf6c65563,
        // 0x7f135b4df21183991e9ff88380c2686dd8634fd4b09bb2b5b14415ac006fe1d,
        // 0x27f2bb7fb0e232befc5aa865ee27ef82839d5fad3e6ec1de598d0fab438cb56,
        // 0x5c678347b60b99b72f245399ba27900b5fc126af11f6637c04a193d508dda26,
        // 0x2906e07881acceff9e4ae4d9dacbcd4239217e5114001844529176e1f0982ec
        ];

        let assets = array![
            contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>(),
            contract_address_const::<0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac>(),
            contract_address_const::<0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8>(),
            contract_address_const::<0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8>(),
            contract_address_const::<0x042b8f0484674ca266ac5d08e4ac6a3fe65bd3129795def2dca5c34ecc5f96d2>(),
            contract_address_const::<0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d>(),
            contract_address_const::<0x0057912720381af14b0e5c87aa4718ed5e527eab60b3801ebf702ab09139e38b>(),
            contract_address_const::<0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87>(),
            contract_address_const::<0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a>(),
            contract_address_const::<0x0356f304b154d29d2A8fe22F1CB9107A9B564A733Cf6b4CC47fd121Ac1af90C9>(),
            contract_address_const::<0x2019e47a0bc54ea6b4853c6123ffc8158ea3ae2af4166928b0de6e89f06de6c>(),
            contract_address_const::<0x498edfaf50ca5855666a700c25dd629d577eb9afccdf3b5977aec79aee55ada>(),
        ];

        let mut i = 0;
        while i < pool_ids.len() {
            let pool_id = *pool_ids.at(i);

            extension.upgrade(extension_v1_class_hash);
            let pool_name = extension.pool_name(pool_id);
            let pool_owner = extension.pool_owner(pool_id);
            let shutdown_mode_agent = extension.shutdown_mode_agent(pool_id);
            let fee_config = extension.fee_config(pool_id);
            let shutdown_config = extension.shutdown_config(pool_id);
            extension.upgrade(extension_v2_class_hash);
            assert!(pool_name == extension.pool_name(pool_id));
            assert!(pool_owner == extension.pool_owner(pool_id));
            assert!(shutdown_mode_agent == extension.shutdown_mode_agent(pool_id));
            assert!(fee_config == extension.fee_config(pool_id));
            assert!(shutdown_config == extension.shutdown_config(pool_id));

            let assets_copy = assets.clone();
            let mut j = 0;
            while j < assets_copy.len() {
                let collateral_asset = *assets_copy.at(j);

                extension.upgrade(extension_v1_class_hash);
                let oracle_config = extension.oracle_config(pool_id, collateral_asset);
                let interest_rate_config = extension.interest_rate_config(pool_id, collateral_asset);
                let v_token_for_collateral_asset = extension.v_token_for_collateral_asset(pool_id, collateral_asset);
                let collateral_asset_for_v_token = extension
                    .collateral_asset_for_v_token(pool_id, v_token_for_collateral_asset);
                extension.upgrade(extension_v2_class_hash);
                assert!(oracle_config == extension.oracle_config(pool_id, collateral_asset));
                assert!(interest_rate_config == extension.interest_rate_config(pool_id, collateral_asset));
                assert!(
                    v_token_for_collateral_asset == extension.v_token_for_collateral_asset(pool_id, collateral_asset),
                );
                assert!(
                    collateral_asset_for_v_token == extension
                        .collateral_asset_for_v_token(pool_id, v_token_for_collateral_asset),
                );

                let assets_copy = assets_copy.clone();
                let mut k = 0;
                while k < assets_copy.len() {
                    let debt_asset = *assets_copy.at(k);

                    extension.upgrade(extension_v1_class_hash);
                    let debt_cap = extension.debt_caps(pool_id, collateral_asset, debt_asset);
                    let liquidation_config = extension.liquidation_config(pool_id, collateral_asset, debt_asset);
                    let shutdown_ltv_config = extension.shutdown_ltv_config(pool_id, collateral_asset, debt_asset);
                    let pairs = extension.pairs(pool_id, collateral_asset, debt_asset);
                    // let shutdown_status = extension.shutdown_status(pool_id, collateral_asset, debt_asset);
                    extension.upgrade(extension_v2_class_hash);
                    assert!(debt_cap == extension.debt_caps(pool_id, collateral_asset, debt_asset));
                    assert!(liquidation_config == extension.liquidation_config(pool_id, collateral_asset, debt_asset));
                    assert!(
                        shutdown_ltv_config == extension.shutdown_ltv_config(pool_id, collateral_asset, debt_asset),
                    );
                    // assert!(shutdown_status == extension.shutdown_status(pool_id, collateral_asset, debt_asset));
                    assert!(pairs == extension.pairs(pool_id, collateral_asset, debt_asset));

                    k += 1;
                }

                j += 1;
            }

            i += 1;
        }
        stop_cheat_caller_address(extension.contract_address);
    }
}
