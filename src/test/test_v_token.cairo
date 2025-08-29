#[cfg(test)]
mod TestVToken {
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use snforge_std::{CheatSpan, DeclareResultTrait, cheat_caller_address, declare};
    use starknet::syscalls::deploy_syscall;
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const};
    use vesu::pool::IPoolDispatcher;
    use vesu::test::setup_v2::{Users, setup};
    use vesu::v_token::{IERC4626Dispatcher, IERC4626DispatcherTrait, IVTokenDispatcher, IVTokenDispatcherTrait};
    use vesu::vendor::erc20::{IERC20MetadataDispatcher, IERC20MetadataDispatcherTrait};

    struct VTokenEnv {
        pool: IPoolDispatcher,
        v_token: IERC4626Dispatcher,
        asset: IERC20Dispatcher,
        users: Users,
    }

    fn setup_v_token() -> VTokenEnv {
        let (pool, _oracle, config, users, _lending) = setup();

        let v_token_class_hash = *declare("VToken").unwrap().contract_class().class_hash;
        let (v_token, _) = (deploy_syscall(
            v_token_class_hash.try_into().unwrap(),
            0,
            array![
                'vToken',
                'vSymbol',
                pool.contract_address.into(),
                config.collateral_asset.contract_address.into(),
                config.debt_asset.contract_address.into(),
            ]
                .span(),
            true,
        ))
            .unwrap();

        let v_token = IERC4626Dispatcher { contract_address: v_token };
        let asset = IERC20Dispatcher { contract_address: config.collateral_asset.contract_address };

        VTokenEnv { pool, v_token, asset, users }
    }

    fn balance_of(v_token: ContractAddress, user: ContractAddress) -> u256 {
        IERC20Dispatcher { contract_address: v_token }.balance_of(user)
    }

    fn allowance(v_token: ContractAddress, owner: ContractAddress, spender: ContractAddress) -> u256 {
        IERC20Dispatcher { contract_address: v_token }.allowance(owner, spender)
    }

    #[test]
    fn test_v_token_getters() {
        let VTokenEnv { pool, v_token, asset, .. } = setup_v_token();

        assert!(
            (IVTokenDispatcher { contract_address: v_token.contract_address }).pool_contract() == pool.contract_address,
        );
        assert!(v_token.asset() == asset.contract_address);

        let metadata = IERC20MetadataDispatcher { contract_address: v_token.contract_address };
        assert!(metadata.name() == 'vToken');
        assert!(metadata.symbol() == 'vSymbol');
        assert!(metadata.decimals() == 18);
    }

    #[test]
    fn test_v_token_flow() {
        let VTokenEnv { v_token, users, asset, .. } = setup_v_token();
        let user_a = users.lender;
        let user_b = contract_address_const::<'user_b'>();
        let user_c = contract_address_const::<'user_c'>();
        let user_d = contract_address_const::<'user_d'>();

        let user_a_initial_balance = asset.balance_of(user_a);

        // Deposit 100 tokens into user_b's account by user_a.
        cheat_caller_address(asset.contract_address, user_a, CheatSpan::TargetCalls(1));
        asset.approve(v_token.contract_address, 100);
        cheat_caller_address(v_token.contract_address, user_a, CheatSpan::TargetCalls(1));
        v_token.deposit(100, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 1000000000000);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);

        // Call withdraw by user_c, from user_b's vToken account into user_d's account.
        cheat_caller_address(v_token.contract_address, user_b, CheatSpan::TargetCalls(1));
        IERC20Dispatcher { contract_address: v_token.contract_address }.approve(user_c, 300000000000);
        assert!(allowance(v_token.contract_address, user_b, user_c) == 300000000000);

        cheat_caller_address(v_token.contract_address, user_c, CheatSpan::TargetCalls(1));
        v_token.withdraw(30, user_d, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 700000000000);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);
        assert!(asset.balance_of(user_c) == 0);
        assert!(asset.balance_of(user_d) == 30);
        // Check that the allowance is zeroed out.
        assert!(allowance(v_token.contract_address, user_b, user_c) == 0);

        // Mint 10 tokens into user_b's account by user_d.
        cheat_caller_address(asset.contract_address, user_d, CheatSpan::TargetCalls(1));
        asset.approve(v_token.contract_address, 10);
        cheat_caller_address(v_token.contract_address, user_d, CheatSpan::TargetCalls(1));
        v_token.mint(100000000000, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 800000000000);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);
        assert!(asset.balance_of(user_c) == 0);
        assert!(asset.balance_of(user_d) == 20);

        // Redeem 10 tokens from user_b's vToken account into user_d's account, by user_c.
        cheat_caller_address(v_token.contract_address, user_b, CheatSpan::TargetCalls(1));
        IERC20Dispatcher { contract_address: v_token.contract_address }.approve(user_c, 100000000000);
        assert!(allowance(v_token.contract_address, user_b, user_c) == 100000000000);

        cheat_caller_address(v_token.contract_address, user_c, CheatSpan::TargetCalls(1));
        v_token.redeem(100000000000, user_d, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 700000000000);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);
        assert!(asset.balance_of(user_c) == 0);
        assert!(asset.balance_of(user_d) == 30);
        // Check that the allowance is zeroed out.
        assert!(allowance(v_token.contract_address, user_b, user_c) == 0);
    }
}
