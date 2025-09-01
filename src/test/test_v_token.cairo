#[cfg(test)]
mod TestVToken {
    use alexandria_math::i257::I257Trait;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use snforge_std::{
        CheatSpan, DeclareResultTrait, cheat_caller_address, declare, load, map_entry_address,
        start_cheat_caller_address, stop_cheat_caller_address, store,
    };
    use starknet::syscalls::deploy_syscall;
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::test::setup_v2::{Users, setup};
    use vesu::units::PERCENT;
    use vesu::v_token::{IERC4626Dispatcher, IERC4626DispatcherTrait, IVTokenDispatcher, IVTokenDispatcherTrait};
    use vesu::vendor::erc20::{IERC20MetadataDispatcher, IERC20MetadataDispatcherTrait};

    struct VTokenEnv {
        pool: IPoolDispatcher,
        v_token: IERC4626Dispatcher,
        asset: IERC20Dispatcher,
        debt_asset: IERC20Dispatcher,
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
        let debt_asset = IERC20Dispatcher { contract_address: config.debt_asset.contract_address };

        VTokenEnv { pool, v_token, asset, debt_asset, users }
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
        let VTokenEnv { pool, v_token, users, asset, .. } = setup_v_token();
        let user_a = users.lender;
        let user_b = contract_address_const::<'user_b'>();
        let user_c = contract_address_const::<'user_c'>();
        let user_d = contract_address_const::<'user_d'>();

        let user_a_initial_balance = asset.balance_of(user_a);

        let to_shares = 10000000000;

        // Deposit 100 tokens into user_b's account by user_a.
        cheat_caller_address(asset.contract_address, user_a, CheatSpan::TargetCalls(1));
        asset.approve(v_token.contract_address, 100);
        cheat_caller_address(v_token.contract_address, user_a, CheatSpan::TargetCalls(1));
        v_token.deposit(100, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 100 * to_shares);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);

        // Call withdraw by user_c, from user_b's vToken account into user_d's account.
        cheat_caller_address(v_token.contract_address, user_b, CheatSpan::TargetCalls(1));
        IERC20Dispatcher { contract_address: v_token.contract_address }.approve(user_c, 300000000000);
        assert!(allowance(v_token.contract_address, user_b, user_c) == 30 * to_shares);

        cheat_caller_address(v_token.contract_address, user_c, CheatSpan::TargetCalls(1));
        v_token.withdraw(30, user_d, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 70 * to_shares);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);
        assert!(asset.balance_of(user_c) == 0);
        assert!(asset.balance_of(user_d) == 30);
        // Check that the allowance is zeroed out.
        assert!(allowance(v_token.contract_address, user_b, user_c) == 0);

        // Artificially double the total amount of shares to check a different conversion rate between
        // shares and assets.
        // Note that this assumes the specific packing of AssetConfig,
        // and it assumes that total_nominal_debt (which is stored in the same felt) is zero.
        let addr = map_entry_address(selector!("asset_configs"), array![asset.contract_address.into()].span());
        let prev_value = *load(pool.contract_address, addr, 1)[0];
        store(pool.contract_address, addr, array![prev_value * 2].span());

        let new_to_shares = 20000000000;

        // Mint 10 tokens into user_b's account by user_d.
        cheat_caller_address(asset.contract_address, user_d, CheatSpan::TargetCalls(1));
        asset.approve(v_token.contract_address, 10);
        cheat_caller_address(v_token.contract_address, user_d, CheatSpan::TargetCalls(1));
        v_token.mint(10 * new_to_shares, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 70 * to_shares + 10 * new_to_shares);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);
        assert!(asset.balance_of(user_c) == 0);
        assert!(asset.balance_of(user_d) == 20);

        // Redeem 10 tokens from user_b's vToken account into user_d's account, by user_c.
        cheat_caller_address(v_token.contract_address, user_b, CheatSpan::TargetCalls(1));
        IERC20Dispatcher { contract_address: v_token.contract_address }.approve(user_c, 10 * new_to_shares);
        assert!(allowance(v_token.contract_address, user_b, user_c) == 10 * new_to_shares);

        cheat_caller_address(v_token.contract_address, user_c, CheatSpan::TargetCalls(1));
        v_token.redeem(10 * new_to_shares, user_d, user_b);

        assert!(balance_of(v_token.contract_address, user_a) == 0);
        assert!(balance_of(v_token.contract_address, user_b) == 70 * to_shares);
        assert!(asset.balance_of(user_a) == user_a_initial_balance - 100);
        assert!(asset.balance_of(user_b) == 0);
        assert!(asset.balance_of(user_c) == 0);
        assert!(asset.balance_of(user_d) == 30);
        // Check that the allowance is zeroed out.
        assert!(allowance(v_token.contract_address, user_b, user_c) == 0);
    }

    #[test]
    fn test_max_withdraw_and_max_redeem() {
        let VTokenEnv { pool, v_token, users, asset, debt_asset, .. } = setup_v_token();

        let to_shares = 10000000000;

        // Set max utilization to 25%.
        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_asset_parameter(asset.contract_address, parameter: 'max_utilization', value: 25 * PERCENT);
        pool.set_asset_parameter(asset.contract_address, parameter: 'floor', value: 0);
        pool.set_asset_parameter(debt_asset.contract_address, parameter: 'floor', value: 0);
        stop_cheat_caller_address(pool.contract_address);

        // Deposit 8000 tokens.
        cheat_caller_address(asset.contract_address, users.lender, CheatSpan::TargetCalls(1));
        asset.approve(v_token.contract_address, 8000);
        cheat_caller_address(v_token.contract_address, users.lender, CheatSpan::TargetCalls(1));
        v_token.deposit(8000, users.lender);

        // User can withdraw all.
        assert!(v_token.max_withdraw(users.lender) == 8000);
        assert!(v_token.max_redeem(users.lender) == 8000 * to_shares);

        // Reserve is at 10000 (8000 + INFLATION_FEE).
        assert!(pool.asset_config(asset.contract_address).reserve == 10000);

        // Transfer some vTokens to another user.
        cheat_caller_address(v_token.contract_address, users.lender, CheatSpan::TargetCalls(1));
        IERC20Dispatcher { contract_address: v_token.contract_address }.transfer(users.borrower, 500 * to_shares + 1);

        // User can withdraw all. max_withdraw is rounded down.
        assert!(v_token.max_withdraw(users.lender) == 7499);
        assert!(v_token.max_redeem(users.lender) == 7500 * to_shares - 1);

        // User takes out 1000 tokens as debt (in their own position).
        cheat_caller_address(debt_asset.contract_address, users.lender, CheatSpan::TargetCalls(1));
        debt_asset.approve(v_token.contract_address, 100000000);
        cheat_caller_address(pool.contract_address, users.lender, CheatSpan::TargetCalls(1));
        pool
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: debt_asset.contract_address,
                    debt_asset: asset.contract_address,
                    user: users.lender,
                    collateral: Amount {
                        denomination: AmountDenomination::Assets, value: I257Trait::new(100000000, is_negative: false),
                    },
                    debt: Amount {
                        denomination: AmountDenomination::Assets, value: I257Trait::new(1000, is_negative: false),
                    },
                },
            );

        // Withdrawing 6000 tokens will leave 3000 in the reserve + 1000 debt, which is the max 25% utilization.
        assert!(v_token.max_withdraw(users.lender) == 6000);
        assert!(v_token.max_redeem(users.lender) == 6000 * to_shares);
    }
}
