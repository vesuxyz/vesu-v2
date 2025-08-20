#[starknet::interface]
trait IFlashLoanGeneric<TContractState> {
    fn flash_loan_amount(self: @TContractState) -> u256;
}

#[starknet::contract]
mod FlashLoanReceiver {
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::singleton_v2::IFlashLoanReceiver;
    use vesu::test::test_flash_loan::IFlashLoanGeneric;

    #[storage]
    struct Storage {
        flash_loan_amount: u256,
    }

    #[abi(embed_v0)]
    impl FlashLoanReceiver of IFlashLoanReceiver<ContractState> {
        fn on_flash_loan(
            ref self: ContractState, sender: ContractAddress, asset: ContractAddress, amount: u256, data: Span<felt252>,
        ) {
            self.flash_loan_amount.write(amount);
        }
    }


    #[abi(embed_v0)]
    impl FlashLoanGenericImpl of IFlashLoanGeneric<ContractState> {
        fn flash_loan_amount(self: @ContractState) -> u256 {
            self.flash_loan_amount.read()
        }
    }
}

#[starknet::contract]
mod MaliciousFlashLoanReceiver {
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const};
    use vesu::singleton_v2::IFlashLoanReceiver;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl FlashLoanReceiver of IFlashLoanReceiver<ContractState> {
        fn on_flash_loan(
            ref self: ContractState, sender: ContractAddress, asset: ContractAddress, amount: u256, data: Span<felt252>,
        ) {
            IERC20Dispatcher { contract_address: asset }.transfer(contract_address_const::<'BadUser'>(), amount);
        }
    }
}

#[cfg(test)]
mod FlashLoan {
    use openzeppelin::token::erc20::ERC20ABIDispatcherTrait;
    use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::singleton_v2::{IFlashLoanReceiverDispatcher, ISingletonV2DispatcherTrait};
    use vesu::test::setup_v2::{LendingTerms, TestConfig, deploy_contract, setup};
    use vesu::test::test_flash_loan::{IFlashLoanGenericDispatcher, IFlashLoanGenericDispatcherTrait};

    #[test]
    fn test_flash_loan_fractional_pool_amount() {
        let (_, singleton, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, .. } = terms;

        let flash_loan_receiver_add = deploy_contract("FlashLoanReceiver");
        let flash_loan_receiver = IFlashLoanReceiverDispatcher { contract_address: flash_loan_receiver_add };
        let flash_loan_receiver_view = IFlashLoanGenericDispatcher { contract_address: flash_loan_receiver_add };

        let initial_lender_debt_asset_balance = debt_asset.balance_of(users.lender);
        let pre_deposit_balance = debt_asset.balance_of(singleton.contract_address);
        // deposit debt asset that will be used in flash loan
        let params = ModifyPositionParams {
            debt_asset: collateral_asset.contract_address,
            collateral_asset: debt_asset.contract_address,
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
        assert!(balance == pre_deposit_balance + liquidity_to_deposit, "Not transferred to Singleton");

        let flash_loan_amount = (balance / 2);

        start_cheat_caller_address(debt_asset.contract_address, flash_loan_receiver.contract_address);
        debt_asset.approve(singleton.contract_address, flash_loan_amount);
        stop_cheat_caller_address(debt_asset.contract_address);

        assert!(
            debt_asset.balance_of(flash_loan_receiver.contract_address) == 0,
            "Flash loan receiver should have 0 balance",
        );

        start_cheat_caller_address(singleton.contract_address, flash_loan_receiver.contract_address);
        singleton
            .flash_loan(
                flash_loan_receiver.contract_address,
                debt_asset.contract_address,
                flash_loan_amount,
                false,
                array![].span(),
            );

        assert!(
            flash_loan_receiver_view.flash_loan_amount() == flash_loan_amount,
            "Flash loan correctly sent to flash loan receiver",
        );
        stop_cheat_caller_address(singleton.contract_address);

        assert!(
            debt_asset.balance_of(flash_loan_receiver.contract_address) == 0,
            "Flash loan receiver should have 0 balance",
        );
        assert!(
            debt_asset.balance_of(singleton.contract_address) == balance, "Singleton should have maintained balance",
        );
    }


    #[test]
    fn test_flash_loan_entire_pool() {
        let (_, singleton, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, .. } = terms;

        let flash_loan_receiver_add = deploy_contract("FlashLoanReceiver");
        let flash_loan_receiver = IFlashLoanReceiverDispatcher { contract_address: flash_loan_receiver_add };
        let flash_loan_receiver_view = IFlashLoanGenericDispatcher { contract_address: flash_loan_receiver_add };

        let initial_lender_debt_asset_balance = debt_asset.balance_of(users.lender);
        let pre_deposit_balance = debt_asset.balance_of(singleton.contract_address);
        // deposit debt asset that will be used in flash loan
        let params = ModifyPositionParams {
            debt_asset: collateral_asset.contract_address,
            collateral_asset: debt_asset.contract_address,
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
        assert!(balance == pre_deposit_balance + liquidity_to_deposit, "Not transferred to Singleton");

        // entire balance of the pool
        let flash_loan_amount = balance;
        start_cheat_caller_address(debt_asset.contract_address, flash_loan_receiver.contract_address);
        debt_asset.approve(singleton.contract_address, flash_loan_amount);
        stop_cheat_caller_address(debt_asset.contract_address);
        start_cheat_caller_address(singleton.contract_address, flash_loan_receiver.contract_address);
        singleton
            .flash_loan(
                flash_loan_receiver.contract_address,
                debt_asset.contract_address,
                flash_loan_amount,
                false,
                array![].span(),
            );

        assert!(
            flash_loan_receiver_view.flash_loan_amount() == flash_loan_amount,
            "Flash loan correctly sent to flash loan receiver",
        );
        stop_cheat_caller_address(singleton.contract_address);

        assert!(
            debt_asset.balance_of(flash_loan_receiver.contract_address) == 0,
            "Flash loan receiver should have 0 balance",
        );
        assert!(
            debt_asset.balance_of(singleton.contract_address) == balance, "Singleton should have maintained balance",
        );
    }

    #[test]
    #[should_panic(expected: ('ERC20: insufficient balance',))]
    fn test_flash_loan_malicious_user() {
        let (_, singleton, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, .. } = terms;

        let malicious_flash_loan_receiver_add = deploy_contract("MaliciousFlashLoanReceiver");
        let malicious_flash_loan_receiver = IFlashLoanReceiverDispatcher {
            contract_address: malicious_flash_loan_receiver_add,
        };

        let initial_lender_debt_asset_balance = debt_asset.balance_of(users.lender);
        let pre_deposit_balance = debt_asset.balance_of(singleton.contract_address);
        // deposit debt asset that will be used in flash loan
        let params = ModifyPositionParams {
            debt_asset: collateral_asset.contract_address,
            collateral_asset: debt_asset.contract_address,
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
        assert!(balance == pre_deposit_balance + liquidity_to_deposit, "Not transferred to Singleton");

        // entire balance of the pool
        let flash_loan_amount = balance;
        start_cheat_caller_address(debt_asset.contract_address, malicious_flash_loan_receiver.contract_address);
        debt_asset.approve(singleton.contract_address, flash_loan_amount);
        stop_cheat_caller_address(debt_asset.contract_address);
        start_cheat_caller_address(singleton.contract_address, malicious_flash_loan_receiver.contract_address);
        singleton
            .flash_loan(
                malicious_flash_loan_receiver.contract_address,
                debt_asset.contract_address,
                flash_loan_amount,
                false,
                array![].span(),
            );
        stop_cheat_caller_address(singleton.contract_address);
    }
}
