#[cfg(test)]
mod TestModifyPosition {
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::ERC20ABIDispatcherTrait;
    use snforge_std::{
        CheatSpan, cheat_caller_address, start_cheat_block_timestamp_global, start_cheat_caller_address,
        stop_cheat_block_timestamp_global, stop_cheat_caller_address,
    };
    #[feature("deprecated-starknet-consts")]
    use starknet::{contract_address_const, get_block_timestamp};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams};
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::oracle::IPragmaOracleDispatcherTrait;
    use vesu::pool::{IPoolDispatcherTrait, IPoolSafeDispatcher, IPoolSafeDispatcherTrait};
    use vesu::test::mock_asset::{IMintableDispatcher, IMintableDispatcherTrait};
    use vesu::test::mock_oracle::{IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait};
    use vesu::test::setup_v2::{COLL_PRAGMA_KEY, LendingTerms, TestConfig, setup, setup_pool};
    use vesu::units::{DAY_IN_SECONDS, SCALE, YEAR_IN_SECONDS};

    // identical-assets

    #[test]
    #[should_panic(expected: "no-delegation")]
    fn test_modify_position_no_delegation() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, third_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit_third, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -liquidity_to_deposit_third.into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "utilization-exceeded")]
    fn test_modify_position_utilization_exceeded() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, third_asset, .. } = config;
        let LendingTerms { collateral_to_deposit, liquidity_to_deposit_third, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // set max utilization
        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_asset_parameter(third_asset.contract_address, 'max_utilization', SCALE / 10);
        stop_cheat_caller_address(pool.contract_address);

        // Borrow

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "debt-cap-exceeded")]
    fn test_modify_position_debt_cap_exceeded() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, third_asset, .. } = config;
        let LendingTerms { collateral_to_deposit, liquidity_to_deposit_third, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // set max utilization
        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_pair_parameter(collateral_asset.contract_address, third_asset.contract_address, 'debt_cap', 1);
        stop_cheat_caller_address(pool.contract_address);

        // Borrow

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "not-collateralized")]
    fn test_modify_position_not_collateralized() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, third_asset, .. } = config;
        let LendingTerms { collateral_to_deposit, liquidity_to_deposit_third, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // Borrow

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Default::default(),
            debt: Amount { denomination: AmountDenomination::Native, value: (SCALE * 3 / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "dusty-collateral-balance")]
    fn test_modify_position_dusty_collateral_balance() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, .. } = terms;

        // set floor to 0
        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_asset_parameter(collateral_asset.contract_address, 'floor', 100_000_000_000); // (* price)
        pool.set_asset_parameter(debt_asset.contract_address, 'floor', 0);
        stop_cheat_caller_address(pool.contract_address);

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: liquidity_to_deposit.into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // Borrow

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: 10.into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: 1.into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "dusty-debt-balance")]
    fn test_modify_position_dusty_debt_balance() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, collateral_to_deposit, .. } = terms;

        // set floor to 0
        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.set_asset_parameter(collateral_asset.contract_address, 'floor', 0);
        pool.set_asset_parameter(debt_asset.contract_address, 'floor', 1_000_000); // (* price)
        stop_cheat_caller_address(pool.contract_address);

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: liquidity_to_deposit.into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // Borrow

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: 1.into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "invalid-oracle")]
    fn test_modify_position_invalid_oracle() {
        let (pool, oracle, config, users, terms) = setup();
        let TestConfig { collateral_asset, third_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit_third, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let mock_pragma_oracle = IMockPragmaOracleDispatcher { contract_address: oracle.pragma_oracle() };
        mock_pragma_oracle.set_num_sources_aggregated(COLL_PRAGMA_KEY, 1);

        pool
            .check_invariants(
                collateral_asset.contract_address,
                third_asset.contract_address,
                users.borrower,
                Zero::zero(),
                Zero::zero(),
                Zero::zero(),
                Zero::zero(),
                false,
            );
    }

    #[test]
    #[should_panic(expected: "unsafe-rate-accumulator")]
    fn test_modify_position_unsafe_rate_accumulator() {
        let current_time = 1707509060;
        start_cheat_block_timestamp_global(current_time);

        let interest_rate_config = InterestRateConfig {
            min_target_utilization: 90_000,
            max_target_utilization: 99_999,
            target_utilization: 99_998,
            min_full_utilization_rate: 100824704600, // 300% per year
            max_full_utilization_rate: 100824704600,
            zero_utilization_rate: 100824704600,
            rate_half_life: 172_800,
            target_rate_percent: SCALE,
        };

        let (pool, _, config, users, terms) = setup_pool(
            Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero(), true, Option::Some(interest_rate_config),
        );

        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, collateral_to_deposit, nominal_debt_to_draw, .. } = terms;

        // User 1

        // deposit collateral which is later borrowed by the borrower
        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: liquidity_to_deposit.into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // User 2

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: nominal_debt_to_draw.into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let current_time = current_time + (360 * DAY_IN_SECONDS);
        start_cheat_block_timestamp_global(current_time);

        pool
            .check_invariants(
                collateral_asset.contract_address,
                debt_asset.contract_address,
                users.lender,
                Zero::zero(),
                Zero::zero(),
                Zero::zero(),
                Zero::zero(),
                false,
            );

        stop_cheat_block_timestamp_global();
    }

    #[test]
    #[fuzzer(runs: 256, seed: 100)]
    fn test_fuzz_modify_position_deposit_withdraw_collateral(seed: u128) {
        let (pool, _, config, users, _) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;

        start_cheat_caller_address(pool.contract_address, users.lender);

        // restrict values slightly to avoid overflow due to inflation mitigation deposit
        let amount: u256 = if seed > 20000000000000 {
            seed.into() - 20000000000000
        } else {
            seed.into()
        };
        let collateral_amount = pool.calculate_collateral(collateral_asset.contract_address, amount.into());
        IMintableDispatcher { contract_address: collateral_asset.contract_address }
            .mint(users.lender, collateral_amount);

        // Delta, Native

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Native, value: amount.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Native, value: -amount.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        // Delta, Assets

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_amount.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -collateral_amount.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        // Target, Native

        let collateral_shares = pool
            .calculate_collateral_shares(collateral_asset.contract_address, collateral_amount.into());

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Native, value: collateral_shares.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Native, value: -collateral_shares.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        // Target, Assets

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_amount.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -collateral_amount.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);
        assert(position.collateral_shares == 0, 'Shares not zero');
    }

    #[test]
    #[fuzzer(runs: 256, seed: 100)]
    fn test_fuzz_modify_position_borrow_repay_debt(seed: u128) {
        let (pool, _, config, users, _) = setup();
        let TestConfig { collateral_asset, debt_asset, debt_scale, .. } = config;

        let amount: u256 = seed.into() / 10000000000000;
        let collateral_amount = pool.calculate_collateral(collateral_asset.contract_address, amount.into());
        let mut debt_amount = pool.calculate_debt(amount.into(), SCALE, debt_scale);
        debt_amount = debt_amount / 2;

        start_cheat_caller_address(pool.contract_address, users.lender);
        IMintableDispatcher { contract_address: debt_asset.contract_address }.mint(users.lender, debt_amount);
        stop_cheat_caller_address(pool.contract_address);

        start_cheat_caller_address(pool.contract_address, users.borrower);
        IMintableDispatcher { contract_address: collateral_asset.contract_address }
            .mint(users.borrower, collateral_amount);
        // compensate for rounding up calculation of repayment amount (in two places)
        IMintableDispatcher { contract_address: debt_asset.contract_address }.mint(users.borrower, debt_amount + 2);

        // Add liquidity

        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: debt_amount.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        // Delta, Native

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Native, value: amount.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (amount / 2).into() },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Native, value: -amount.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: -(amount / 2).into() },
        };

        pool.modify_position(params);

        // Delta, Assets

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_amount.into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: debt_amount.into() },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -collateral_amount.into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: -debt_amount.into() },
        };

        pool.modify_position(params);

        let collateral_shares = pool
            .calculate_collateral_shares(collateral_asset.contract_address, collateral_amount.into());

        // Target, Native

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Native, value: collateral_shares.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (collateral_shares / 2).into() },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Native, value: -collateral_shares.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: -(collateral_shares / 2).into() },
        };

        pool.modify_position(params);

        // Target, Assets

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_amount.into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: debt_amount.into() },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -collateral_amount.into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: -debt_amount.into() },
        };

        pool.modify_position(params);

        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);
        assert(position.collateral_shares == 0 && position.nominal_debt == 0, 'Position not zero');
    }

    #[test]
    fn test_modify_position_collateral_amounts() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, .. } = config;
        let LendingTerms { collateral_to_deposit, .. } = terms;

        let inflation_fee: u256 = 2000_0000000000; // 2x for each pair

        start_cheat_caller_address(pool.contract_address, users.lender);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (collateral_to_deposit / 2).into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let asset_config = pool.asset_config(collateral_asset.contract_address);
        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);

        assert(
            asset_config.total_collateral_shares - inflation_fee == position.collateral_shares, 'Shares not matching',
        );
        stop_cheat_caller_address(pool.contract_address);

        let pool_donation = collateral_to_deposit / 2;
        cheat_caller_address(collateral_asset.contract_address, users.lender, CheatSpan::TargetCalls(1));
        collateral_asset.transfer(users.curator, pool_donation);
        cheat_caller_address(collateral_asset.contract_address, users.curator, CheatSpan::TargetCalls(1));
        collateral_asset.approve(pool.contract_address, pool_donation);
        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.donate_to_reserve(collateral_asset.contract_address, pool_donation);

        start_cheat_caller_address(pool.contract_address, users.lender);
        let asset_config = pool.asset_config(collateral_asset.contract_address);
        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);
        assert(
            asset_config.total_collateral_shares - inflation_fee == position.collateral_shares, 'Shares not matching',
        );

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -(collateral_to_deposit / 4).into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let asset_config = pool.asset_config(collateral_asset.contract_address);
        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);
        assert(
            asset_config.total_collateral_shares - inflation_fee == position.collateral_shares, 'Shares not matching',
        );

        let collateral_shares = pool
            .calculate_collateral_shares(collateral_asset.contract_address, (collateral_to_deposit / 2).into());

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Native, value: collateral_shares.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let collateral_shares = pool
            .calculate_collateral_shares(collateral_asset.contract_address, -(collateral_to_deposit / 4).into());

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Native, value: -collateral_shares.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -(collateral_to_deposit / 4).into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let collateral_shares = pool
            .calculate_collateral_shares(collateral_asset.contract_address, (collateral_to_deposit * 3 / 4).into());

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Native, value: (collateral_shares).into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let (current_position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount {
                denomination: AmountDenomination::Native, value: -(current_position.collateral_shares).into(),
            },
            debt: Default::default(),
        };

        pool.modify_position(params);

        let asset_config = pool.asset_config(collateral_asset.contract_address);
        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);
        assert(
            asset_config.total_collateral_shares - inflation_fee == position.collateral_shares, 'Shares not matching',
        );
        // rounding error might leave some extra units in the pool
        assert(asset_config.reserve == 4000, 'Reserve not zero');
        assert(asset_config.total_collateral_shares == 2000_0000000000, 'Total shares not zero');

        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    fn test_modify_position_debt_amounts() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, debt_scale, .. } = config;
        let LendingTerms { liquidity_to_deposit, collateral_to_deposit, debt_to_draw, .. } = terms;

        start_cheat_caller_address(pool.contract_address, users.lender);

        // add liquidity
        let params = ModifyPositionParams {
            debt_asset: collateral_asset.contract_address,
            collateral_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: liquidity_to_deposit.into() },
            debt: Default::default(),
        };

        pool.modify_position(params);

        // collateralize position
        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Default::default(),
        };

        start_cheat_block_timestamp_global(get_block_timestamp() + DAY_IN_SECONDS);

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Default::default(),
            debt: Amount { denomination: AmountDenomination::Assets, value: (debt_to_draw / 2).into() },
        };

        pool.modify_position(params);

        let (position, _, debt) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);
        assert(position.nominal_debt < debt * SCALE / debt_scale, 'No interest');

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Default::default(),
            debt: Amount { denomination: AmountDenomination::Assets, value: -(debt_to_draw / 4).into() },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Default::default(),
            debt: Amount {
                denomination: AmountDenomination::Native, value: ((debt_to_draw / 2) * SCALE / debt_scale).into(),
            },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Default::default(),
            debt: Amount {
                denomination: AmountDenomination::Native, value: -((debt_to_draw / 4) * SCALE / debt_scale).into(),
            },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Default::default(),
            debt: Amount { denomination: AmountDenomination::Assets, value: -(debt_to_draw / 4).into() },
        };

        pool.modify_position(params);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Default::default(),
            debt: Amount {
                denomination: AmountDenomination::Native, value: ((debt_to_draw * SCALE / debt_scale) / 4).into(),
            },
        };

        pool.modify_position(params);

        let (current_position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Default::default(),
            debt: Amount { denomination: AmountDenomination::Native, value: -(current_position.nominal_debt).into() },
        };

        pool.modify_position(params);

        let asset_config = pool.asset_config(debt_asset.contract_address);
        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.lender);
        assert(asset_config.total_nominal_debt == position.nominal_debt, 'Shares not matching');
        assert(asset_config.total_nominal_debt == 0, 'Total nominal debt not zero');

        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    fn test_modify_position_complex() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, debt_scale, .. } = config;
        let LendingTerms {
            liquidity_to_deposit, collateral_to_deposit, debt_to_draw, nominal_debt_to_draw, ..,
        } = terms;

        let initial_lender_debt_asset_balance = debt_asset.balance_of(users.lender);
        let initial_borrower_collateral_asset_balance = collateral_asset.balance_of(users.borrower);
        let initial_borrower_debt_asset_balance = debt_asset.balance_of(users.borrower);
        let initial_pool_debt_asset_balance = debt_asset.balance_of(pool.contract_address);

        // LENDER

        // deposit collateral which is later borrowed by the borrower
        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: liquidity_to_deposit.into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // check that liquidity has been deposited
        let balance = debt_asset.balance_of(users.lender);
        assert!(balance == initial_lender_debt_asset_balance - liquidity_to_deposit, "Not transferred from Lender");

        let balance = debt_asset.balance_of(pool.contract_address);
        assert!(
            balance == initial_pool_debt_asset_balance + liquidity_to_deposit, "Not transferred to Pool",
        ); // 2 due to inflation mitigation

        let (position, collateral, debt) = pool
            .position(debt_asset.contract_address, collateral_asset.contract_address, users.lender);

        assert!(collateral == liquidity_to_deposit, "Collateral not set");
        assert!(position.nominal_debt == 0, "Nominal Debt should be 0");
        assert!(debt == 0, "Debt should be 0");

        // BORROWER

        let initial_pool_collateral_asset_balance = collateral_asset.balance_of(pool.contract_address);

        // deposit collateral and debt assets
        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: nominal_debt_to_draw.into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // check that collateral has been deposited and the targeted amount has been borrowed

        // collateral asset has been transferred from the borrower to the pool
        let balance = collateral_asset.balance_of(users.borrower);
        assert!(
            balance == initial_borrower_collateral_asset_balance - collateral_to_deposit,
            "Not transferred from borrower",
        );
        let balance = collateral_asset.balance_of(pool.contract_address);
        assert!(balance == initial_pool_collateral_asset_balance + collateral_to_deposit, "Not transferred to Pool");

        // debt asset has been transferred from the pool to the borrower
        let balance = debt_asset.balance_of(users.borrower);
        assert!(balance == initial_borrower_debt_asset_balance + debt_to_draw, "Debt asset not transferred");
        let balance = debt_asset.balance_of(pool.contract_address);
        assert!(
            balance == initial_pool_debt_asset_balance + liquidity_to_deposit - debt_to_draw,
            "Debt asset not transferred",
        );

        // collateral asset reserve has been updated
        let asset_config = pool.asset_config(collateral_asset.contract_address);
        assert!(
            asset_config.reserve == initial_pool_collateral_asset_balance + collateral_to_deposit,
            "Collateral not in reserve",
        );

        // debt asset reserve has been updated
        let asset_config = pool.asset_config(debt_asset.contract_address);
        assert!(
            asset_config.reserve == initial_pool_debt_asset_balance + liquidity_to_deposit - debt_to_draw,
            "Debt not taken from reserve",
        );

        // position's collateral balance has been updated
        let (position, collateral, debt) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.borrower);
        // assert!(
        //     position.collateral_shares == collateral_to_deposit * SCALE / collateral_scale, "Collateral Shares not
        //     set"
        // );
        assert!(collateral == collateral_to_deposit, "Collateral not set");
        // position's debt balance has been updated (no interest accrued yet)
        assert!(position.nominal_debt == nominal_debt_to_draw, "Nominal Debt not set");
        assert!(debt == nominal_debt_to_draw * debt_scale / SCALE, "Debt not set");
        let collateral_shares = position.collateral_shares;
        // interest accrued should be reflected since time has passed
        start_cheat_block_timestamp_global(get_block_timestamp() + DAY_IN_SECONDS);
        let (position, collateral, debt) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.borrower);
        assert!(position.collateral_shares == collateral_shares, "C.S. should not change");
        assert!(collateral == collateral_to_deposit, "Collateral should not change");
        assert!(position.nominal_debt == nominal_debt_to_draw, "Nominal Debt should not change");
        assert!(debt > nominal_debt_to_draw * debt_scale / SCALE, "Debt should accrue due interest");

        // repay debt assets
        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -(collateral_to_deposit / 2).into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: -(debt_to_draw / 2).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // check that some debt has been repayed and that some collateral has been withdrawn
        let balance = debt_asset.balance_of(users.borrower);
        assert!(
            balance <= initial_borrower_debt_asset_balance + debt_to_draw - debt_to_draw / 2,
            "Debt asset not transferred",
        );

        let balance = debt_asset.balance_of(pool.contract_address);
        assert!(balance >= liquidity_to_deposit - debt_to_draw + debt_to_draw / 2, "Debt asset not transferred");

        let asset_config = pool.asset_config(debt_asset.contract_address);
        assert!(
            asset_config.reserve >= liquidity_to_deposit - debt_to_draw + debt_to_draw / 2,
            "Repayed assets not in reserve",
        );

        let (position, _, debt) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.borrower);

        assert!(position.nominal_debt < nominal_debt_to_draw, "Nominal Debt should be less");
        assert!(debt < debt_to_draw, "Debt should be less");

        let balance = collateral_asset.balance_of(users.borrower);
        assert!(
            balance <= initial_borrower_collateral_asset_balance - collateral_to_deposit / 2,
            "Collateral not transferred",
        );

        let balance = collateral_asset.balance_of(pool.contract_address);
        assert!(balance >= collateral_to_deposit / 2, "Collateral not transferred");

        let asset_config = pool.asset_config(collateral_asset.contract_address);
        assert!(asset_config.reserve >= collateral_to_deposit / 2, "Withdrawn assets not in reserve");

        // fund borrower with debt assets to repay interest
        start_cheat_caller_address(debt_asset.contract_address, users.lender);
        debt_asset.transfer(users.borrower, debt_to_draw);
        stop_cheat_caller_address(debt_asset.contract_address);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: -collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Assets, value: -nominal_debt_to_draw.into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // check that all debt has been repayed and all collateral has been withdrawn
        assert!(debt_asset.balance_of(pool.contract_address) >= liquidity_to_deposit, "Debt asset not transferred");

        let asset_config = pool.asset_config(debt_asset.contract_address);
        assert!(asset_config.reserve >= liquidity_to_deposit, "Repayed assets not in reserve");

        let balance = collateral_asset.balance_of(users.borrower);
        assert!(balance == initial_borrower_collateral_asset_balance, "Collateral not transferred");

        let (position, _, _) = pool
            .position(collateral_asset.contract_address, debt_asset.contract_address, users.borrower);
        assert!(position.collateral_shares == 0, "Collateral Shares should be 0");
        assert!(position.nominal_debt == 0, "Nominal Debt should be 0");

        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    fn test_modify_position_fees() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, third_asset, third_scale, .. } = config;
        let LendingTerms { collateral_to_deposit, liquidity_to_deposit_third, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        // let asset_config = pool.asset_config(third_asset.contract_address);
        // let reserve = asset_config.reserve;

        // Borrow

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let asset_config = pool.asset_config(third_asset.contract_address);
        let total_collateral_shares = asset_config.total_collateral_shares;

        let pair = pool.pairs(collateral_asset.contract_address, third_asset.contract_address);
        assert(pair.total_collateral_shares > 0 && pair.total_nominal_debt > 0, 'Pair not initialized');

        start_cheat_block_timestamp_global(get_block_timestamp() + YEAR_IN_SECONDS.try_into().unwrap());

        // fund borrower with debt assets to repay interest
        start_cheat_caller_address(third_asset.contract_address, users.lender);
        third_asset.transfer(users.borrower, third_scale);
        stop_cheat_caller_address(third_asset.contract_address);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Default::default(),
            debt: Amount { denomination: AmountDenomination::Native, value: -(SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let (fee_shares, fee_amount) = pool.get_fees(third_asset.contract_address);
        assert(fee_shares > 0, 'Fee shares not minted');

        // fees increase total_collateral_shares
        let asset_config = pool.asset_config(third_asset.contract_address);
        let reserve = asset_config.reserve;
        assert(asset_config.total_collateral_shares == total_collateral_shares + fee_shares, 'Shares not increased');
        assert(asset_config.fee_shares > 0, 'Fee shares not increased');

        // withdraw fees
        let balance_before = third_asset.balance_of(users.curator);
        cheat_caller_address(pool.contract_address, users.curator, CheatSpan::TargetCalls(1));
        pool.claim_fees(third_asset.contract_address, 0);
        let balance_after = third_asset.balance_of(users.curator);
        assert(balance_before < balance_after, 'Fees not claimed');
        assert(balance_before + fee_amount == balance_after, 'Wrong fee amount');

        let asset_config = pool.asset_config(third_asset.contract_address);
        assert(asset_config.total_collateral_shares == total_collateral_shares, 'Shares not decreased');
        assert(asset_config.reserve == reserve - fee_amount, 'Reserve not decreased');
        assert(asset_config.fee_shares == 0, 'Fee shares not decreased');
    }

    #[test]
    fn test_modify_position_accrue_interest() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, third_asset, third_scale, .. } = config;
        let LendingTerms { collateral_to_deposit, liquidity_to_deposit_third, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let (mut collateral_fee_shares_before, _) = pool.get_fees(third_asset.contract_address);

        // Borrow

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Amount { denomination: AmountDenomination::Assets, value: collateral_to_deposit.into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let (fee_shares, _) = pool.get_fees(third_asset.contract_address);
        assert(collateral_fee_shares_before == fee_shares, 'no fees shouldve accrued');

        let asset_config = pool.asset_config(third_asset.contract_address);
        let total_collateral_shares = asset_config.total_collateral_shares;

        start_cheat_block_timestamp_global(get_block_timestamp() + YEAR_IN_SECONDS.try_into().unwrap());

        // Repay 1

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Default::default(),
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let (fee_shares, _) = pool.get_fees(third_asset.contract_address);
        assert(collateral_fee_shares_before < fee_shares, 'fees shouldve accrued');
        collateral_fee_shares_before = fee_shares;

        let rate_accumulator = pool.rate_accumulator(third_asset.contract_address);

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        assert(pool.rate_accumulator(third_asset.contract_address) == rate_accumulator, 'rate_accumulator changed');

        // fund borrower with debt assets to repay interest
        start_cheat_caller_address(third_asset.contract_address, users.lender);
        third_asset.transfer(users.borrower, third_scale);
        stop_cheat_caller_address(third_asset.contract_address);

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: third_asset.contract_address,
            user: users.borrower,
            collateral: Default::default(),
            debt: Amount { denomination: AmountDenomination::Native, value: -(SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.borrower);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let (fee_shares, _) = pool.get_fees(third_asset.contract_address);
        assert(collateral_fee_shares_before == fee_shares, 'fees shouldve accrued');
        assert(fee_shares > 0, 'Fee shares not minted');

        // fees increase total_collateral_shares
        let asset_config = pool.asset_config(third_asset.contract_address);
        assert(asset_config.total_collateral_shares > total_collateral_shares, 'Shares not increased');

        // withdraw fees
        let fee_recipient = contract_address_const::<'fee_recipient'>();
        let (_, fee_amount) = pool.get_fees(third_asset.contract_address);
        let balance_before = third_asset.balance_of(users.curator);

        #[feature("safe_dispatcher")]
        assert!(
            !IPoolSafeDispatcher { contract_address: pool.contract_address }
                .claim_fees(third_asset.contract_address, 0)
                .is_ok(),
        );

        start_cheat_caller_address(pool.contract_address, users.curator);
        pool.claim_fees(third_asset.contract_address, fee_shares / 2);
        let (rest, _) = pool.get_fees(third_asset.contract_address);
        assert(rest > 0, 'All fees claimed');
        pool.claim_fees(third_asset.contract_address, 0);

        pool.set_fee_recipient(fee_recipient);
        stop_cheat_caller_address(pool.contract_address);

        start_cheat_caller_address(pool.contract_address, fee_recipient);
        pool.claim_fees(third_asset.contract_address, 0);
        stop_cheat_caller_address(pool.contract_address);

        let balance_after = third_asset.balance_of(users.curator);
        assert(balance_before < balance_after, 'Fees not claimed');
        assert(balance_before + fee_amount - 1 == balance_after, 'Wrong fee amount');
    }

    #[test]
    #[should_panic(expected: "asset-config-nonexistent")]
    fn test_modify_position_zero_asset() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { debt_asset, .. } = config;
        let LendingTerms { liquidity_to_deposit, .. } = terms;

        // Supply

        let params = ModifyPositionParams {
            collateral_asset: debt_asset.contract_address,
            debt_asset: Zero::zero(),
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }

    #[test]
    #[should_panic(expected: "not-collateralized")]
    fn test_modify_position_no_pair() {
        let (pool, _, config, users, terms) = setup();
        let TestConfig { collateral_asset, debt_asset, third_asset, .. } = config;
        let LendingTerms { collateral_to_deposit, liquidity_to_deposit_third, .. } = terms;

        let params = ModifyPositionParams {
            collateral_asset: collateral_asset.contract_address,
            debt_asset: debt_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (collateral_to_deposit).into() },
            debt: Default::default(),
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);

        let pair_config = pool.pair_config(third_asset.contract_address, collateral_asset.contract_address);
        assert(pair_config.max_ltv == 0, 'Pair should not exist');

        let params = ModifyPositionParams {
            collateral_asset: third_asset.contract_address,
            debt_asset: collateral_asset.contract_address,
            user: users.lender,
            collateral: Amount { denomination: AmountDenomination::Assets, value: (liquidity_to_deposit_third).into() },
            debt: Amount { denomination: AmountDenomination::Native, value: (SCALE / 4).into() },
        };

        start_cheat_caller_address(pool.contract_address, users.lender);
        pool.modify_position(params);
        stop_cheat_caller_address(pool.contract_address);
    }
}
