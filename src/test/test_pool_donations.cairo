#[cfg(test)]
mod TestPoolDonation {
    use alexandria_math::i257::I257Trait;
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use snforge_std::{
        CheatSpan, ContractClass, ContractClassTrait, cheat_caller_address, get_class_hash,
        start_cheat_block_timestamp_global, start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::get_block_timestamp;
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::math::pow_10;
    use vesu::singleton_v2::ISingletonV2DispatcherTrait;
    use vesu::test::setup_v2::{LendingTerms, TestConfig, setup};
    use vesu::units::{DAY_IN_SECONDS, PERCENT};

    #[test]
    fn test_donate_to_reserve_pool() {
        let (singleton, extension, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, debt_scale, .. } = config;
        let LendingTerms { liquidity_to_deposit, collateral_to_deposit, nominal_debt_to_draw, .. } = terms;

        let initial_lender_debt_asset_balance = debt_asset.balance_of(users.lender);

        assert!(singleton.extension().is_non_zero(), "Pool not created");

        start_cheat_caller_address(singleton.contract_address, extension.contract_address);
        singleton.set_asset_parameter(debt_asset.contract_address, 'fee_rate', 10 * PERCENT);
        stop_cheat_caller_address(singleton.contract_address);

        let initial_singleton_debt_asset_balance = debt_asset.balance_of(singleton.contract_address);

        // LENDER

        // deposit collateral which is later borrowed by the borrower
        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: liquidity_to_deposit.into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(singleton.contract_address, users.lender);
        singleton.modify_position(params);
        stop_cheat_caller_address(singleton.contract_address);

        // check that liquidity has been deposited
        let balance = debt_asset.balance_of(users.lender);
        assert!(balance == initial_lender_debt_asset_balance - liquidity_to_deposit, "Not transferred from Lender");

        let balance = debt_asset.balance_of(singleton.contract_address);
        assert!(balance == initial_singleton_debt_asset_balance + liquidity_to_deposit, "Not transferred to Singleton");

        let (old_position, collateral, _) = singleton
            .position(debt_asset.contract_address, collateral_asset.contract_address, users.lender);

        assert!(collateral == liquidity_to_deposit, "Collateral not set");

        let asset_config = singleton.asset_config(debt_asset.contract_address);
        let old_pool_reserve = asset_config.reserve;

        let amount_to_donate_to_reserve = 25 * debt_scale;

        // BORROWER

        // deposit collateral and debt assets
        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: nominal_debt_to_draw.into() },
        };

        start_cheat_caller_address(singleton.contract_address, users.borrower);
        let response = singleton.modify_position(params);
        stop_cheat_caller_address(singleton.contract_address);

        let (fee_shares, _) = singleton.get_fees(debt_asset.contract_address);
        assert!(fee_shares == 0, "No fee shares should not have accrued");

        // interest accrued should be reflected since time has passed
        start_cheat_block_timestamp_global(get_block_timestamp() + DAY_IN_SECONDS);

        let (fee_shares_before, _) = singleton.get_fees(debt_asset.contract_address);
        assert!(fee_shares_before > 0, "Fee shares should have been accrued");

        cheat_caller_address(debt_asset.contract_address, users.lender, CheatSpan::TargetCalls(1));
        debt_asset.transfer(users.extension_owner, amount_to_donate_to_reserve);
        cheat_caller_address(debt_asset.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        debt_asset.approve(singleton.contract_address, amount_to_donate_to_reserve);
        cheat_caller_address(singleton.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        singleton.donate_to_reserve(debt_asset.contract_address, amount_to_donate_to_reserve);

        let (fee_shares_after, _) = singleton.get_fees(debt_asset.contract_address);
        assert!(fee_shares_after == fee_shares_before, "Fee shares mismatch");

        let balance = debt_asset.balance_of(users.lender);
        assert!(
            balance == initial_lender_debt_asset_balance - liquidity_to_deposit - amount_to_donate_to_reserve,
            "Not transferred from Lender",
        );

        let (new_position, _, _) = singleton
            .position(debt_asset.contract_address, collateral_asset.contract_address, users.lender);

        assert!(new_position.collateral_shares == old_position.collateral_shares, "Collateral shares should unchanged");

        let asset_config = singleton.asset_config(debt_asset.contract_address);
        let new_pool_reserve = asset_config.reserve;
        assert!(
            new_pool_reserve == old_pool_reserve + amount_to_donate_to_reserve - response.debt_delta.abs(),
            "Reserves not updated",
        );
    }

    #[test]
    #[should_panic(expected: "asset-config-nonexistent")]
    fn test_donate_to_reserve_pool_incorrect_asset() {
        let (singleton, _, config, users, _) = setup();
        let TestConfig { debt_asset, .. } = config;

        let mock_asset_class = ContractClass { class_hash: get_class_hash(debt_asset.contract_address) };

        let decimals = 8;
        let fake_asset_scale = pow_10(decimals);
        let supply = 5 * fake_asset_scale;
        let calldata = array![
            'Fake', 'FKE', decimals.into(), supply.low.into(), supply.high.into(), users.lender.into(),
        ];
        let (contract_address, _) = mock_asset_class.deploy(@calldata).unwrap();
        let fake_asset = IERC20Dispatcher { contract_address };

        assert!(fake_asset.balance_of(users.lender) == supply, "Fake asset not minted");
        start_cheat_caller_address(singleton.contract_address, users.lender);
        fake_asset.approve(singleton.contract_address, supply);
        stop_cheat_caller_address(singleton.contract_address);

        assert!(singleton.extension().is_non_zero(), "Pool not created");

        let amount_to_donate_to_reserve = 2 * fake_asset_scale;

        cheat_caller_address(fake_asset.contract_address, users.lender, CheatSpan::TargetCalls(1));
        fake_asset.transfer(users.owner, amount_to_donate_to_reserve);
        cheat_caller_address(fake_asset.contract_address, users.owner, CheatSpan::TargetCalls(1));
        fake_asset.approve(singleton.contract_address, amount_to_donate_to_reserve);
        cheat_caller_address(singleton.contract_address, users.extension_owner, CheatSpan::TargetCalls(1));
        singleton.donate_to_reserve(fake_asset.contract_address, amount_to_donate_to_reserve);
    }
}
