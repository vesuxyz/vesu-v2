use core::num::traits::{Bounded, Zero};
use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, cheat_caller_address, declare,
    start_cheat_block_timestamp_global, start_cheat_caller_address, stop_cheat_caller_address,
};
#[feature("deprecated-starknet-consts")]
use starknet::{ContractAddress, contract_address_const, get_block_timestamp, get_contract_address};
use vesu::data_model::{AssetParams, DebtCapParams, LTVConfig, LTVParams};
use vesu::extension::components::interest_rate_model::InterestRateConfig;
use vesu::extension::components::position_hooks::{LiquidationConfig, ShutdownConfig};
use vesu::extension::default_extension_po_v2::{
    FeeParams, IDefaultExtensionPOV2Dispatcher, IDefaultExtensionPOV2DispatcherTrait, LiquidationParams,
    PragmaOracleParams, ShutdownParams,
};
use vesu::math::pow_10;
use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
use vesu::test::mock_oracle::{
    IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait, IMockPragmaSummaryDispatcher,
};
use vesu::units::{DAY_IN_SECONDS, INFLATION_FEE, PERCENT, SCALE, SCALE_128};
use vesu::vendor::pragma::AggregationMode;

pub const COLL_PRAGMA_KEY: felt252 = 19514442401534788;
pub const DEBT_PRAGMA_KEY: felt252 = 5500394072219931460;
pub const THIRD_PRAGMA_KEY: felt252 = 18669995996566340;

#[derive(Copy, Drop, Serde)]
pub struct Users {
    pub owner: ContractAddress,
    pub lender: ContractAddress,
    pub borrower: ContractAddress,
    pub seeder: ContractAddress,
}

#[derive(Copy, Drop, Serde)]
pub struct LendingTerms {
    pub liquidity_to_deposit: u256,
    pub liquidity_to_deposit_third: u256,
    pub collateral_to_deposit: u256,
    pub debt_to_draw: u256,
    pub rate_accumulator: u256,
    pub nominal_debt_to_draw: u256,
}

#[derive(Copy, Drop, Serde)]
pub struct Env {
    pub singleton: ISingletonV2Dispatcher,
    pub extension: IDefaultExtensionPOV2Dispatcher,
    pub config: TestConfig,
    pub users: Users,
}

#[derive(Copy, Drop, Serde)]
pub struct TestConfig {
    pub collateral_asset: IERC20Dispatcher,
    pub debt_asset: IERC20Dispatcher,
    pub third_asset: IERC20Dispatcher,
    pub collateral_scale: u256,
    pub debt_scale: u256,
    pub third_scale: u256,
}

pub fn deploy_contract(name: ByteArray) -> ContractAddress {
    let (contract_address, _) = declare(name).unwrap().contract_class().deploy(@array![]).unwrap();
    contract_address
}

pub fn deploy_with_args(name: ByteArray, constructor_args: Array<felt252>) -> ContractAddress {
    let (contract_address, _) = declare(name).unwrap().contract_class().deploy(@constructor_args).unwrap();
    contract_address
}

pub fn deploy_assets(recipient: ContractAddress) -> (IERC20Dispatcher, IERC20Dispatcher, IERC20Dispatcher) {
    // mint 100 collateral and debt assets

    let decimals = 8;
    let supply = 100 * pow_10(decimals);
    let calldata = array![
        'Collateral', 'COLL', decimals.into(), supply.low.into(), supply.high.into(), recipient.into(),
    ];
    let collateral_asset = IERC20Dispatcher { contract_address: deploy_with_args("MockAsset", calldata) };

    let decimals = 12;
    let supply = 100 * pow_10(decimals);
    let calldata = array!['Debt', 'DEBT', decimals.into(), supply.low.into(), supply.high.into(), recipient.into()];
    let debt_asset = IERC20Dispatcher { contract_address: deploy_with_args("MockAsset", calldata) };

    let decimals = 18;
    let supply = 100 * pow_10(decimals);
    let calldata = array!['Third', 'THIRD', decimals.into(), supply.low.into(), supply.high.into(), recipient.into()];
    let third_asset = IERC20Dispatcher { contract_address: deploy_with_args("MockAsset", calldata) };

    (collateral_asset, debt_asset, third_asset)
}

pub fn deploy_asset(recipient: ContractAddress) -> IERC20Dispatcher {
    deploy_asset_with_decimals(recipient, 18)
}

pub fn deploy_asset_with_decimals(recipient: ContractAddress, decimals: u32) -> IERC20Dispatcher {
    let supply = 100 * pow_10(decimals);
    let calldata = array!['Asset', 'ASSET', decimals.into(), supply.low.into(), supply.high.into(), recipient.into()];
    let asset = IERC20Dispatcher { contract_address: deploy_with_args("MockAsset", calldata) };
    asset
}

pub fn setup_env(
    oracle_address: ContractAddress,
    collateral_address: ContractAddress,
    debt_address: ContractAddress,
    third_address: ContractAddress,
) -> Env {
    let users = Users {
        owner: contract_address_const::<'owner'>(),
        lender: contract_address_const::<'lender'>(),
        borrower: contract_address_const::<'borrower'>(),
        seeder: contract_address_const::<'seeder'>(),
    };

    let singleton = ISingletonV2Dispatcher {
        contract_address: deploy_with_args("SingletonV2", array![users.owner.into()]),
    };

    start_cheat_block_timestamp_global(get_block_timestamp() + 1);

    let mock_pragma_oracle = IMockPragmaOracleDispatcher {
        contract_address: if oracle_address.is_non_zero() {
            oracle_address
        } else {
            deploy_contract("MockPragmaOracle")
        },
    };

    let mock_pragma_summary = IMockPragmaSummaryDispatcher { contract_address: deploy_contract("MockPragmaSummary") };

    let args = array![
        singleton.contract_address.into(),
        mock_pragma_oracle.contract_address.into(),
        mock_pragma_summary.contract_address.into(),
    ];
    let extension = IDefaultExtensionPOV2Dispatcher {
        contract_address: deploy_with_args("DefaultExtensionPOV2", args),
    };

    // deploy collateral and borrow assets
    let (collateral_asset, debt_asset, third_asset) = if collateral_address.is_non_zero()
        && debt_address.is_non_zero()
        && third_address.is_non_zero() {
        (
            IERC20Dispatcher { contract_address: collateral_address },
            IERC20Dispatcher { contract_address: debt_address },
            IERC20Dispatcher { contract_address: third_address },
        )
    } else {
        deploy_assets(users.lender)
    };

    // transfer 2x INFLATION_FEE to owner
    start_cheat_caller_address(collateral_asset.contract_address, users.lender);
    collateral_asset.transfer(users.owner, INFLATION_FEE * 2);
    stop_cheat_caller_address(collateral_asset.contract_address);
    start_cheat_caller_address(debt_asset.contract_address, users.lender);
    debt_asset.transfer(users.owner, INFLATION_FEE * 2);
    stop_cheat_caller_address(debt_asset.contract_address);
    start_cheat_caller_address(third_asset.contract_address, users.lender);
    third_asset.transfer(users.owner, INFLATION_FEE * 2);
    stop_cheat_caller_address(third_asset.contract_address);

    // approve Extension and ExtensionV2 to transfer assets on behalf of owner
    start_cheat_caller_address(collateral_asset.contract_address, users.owner);
    collateral_asset.approve(extension.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(collateral_asset.contract_address);
    start_cheat_caller_address(debt_asset.contract_address, users.owner);
    debt_asset.approve(extension.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(debt_asset.contract_address);
    start_cheat_caller_address(third_asset.contract_address, users.owner);
    third_asset.approve(extension.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(third_asset.contract_address);

    // approve Singleton to transfer assets on behalf of lender
    start_cheat_caller_address(debt_asset.contract_address, users.lender);
    debt_asset.approve(singleton.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(debt_asset.contract_address);
    start_cheat_caller_address(collateral_asset.contract_address, users.lender);
    collateral_asset.approve(singleton.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(collateral_asset.contract_address);
    start_cheat_caller_address(third_asset.contract_address, users.lender);
    third_asset.approve(singleton.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(third_asset.contract_address);

    // approve Singleton to transfer assets on behalf of borrower
    start_cheat_caller_address(debt_asset.contract_address, users.borrower);
    debt_asset.approve(singleton.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(debt_asset.contract_address);
    start_cheat_caller_address(collateral_asset.contract_address, users.borrower);
    collateral_asset.approve(singleton.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(collateral_asset.contract_address);
    start_cheat_caller_address(third_asset.contract_address, users.borrower);
    third_asset.approve(singleton.contract_address, Bounded::<u256>::MAX);
    stop_cheat_caller_address(third_asset.contract_address);

    if oracle_address.is_zero() {
        mock_pragma_oracle.set_price(COLL_PRAGMA_KEY, SCALE_128);
        mock_pragma_oracle.set_price(DEBT_PRAGMA_KEY, SCALE_128);
        mock_pragma_oracle.set_price(THIRD_PRAGMA_KEY, SCALE_128);
    }

    // create pool config
    let collateral_scale = pow_10(collateral_asset.decimals().into());
    let debt_scale = pow_10(debt_asset.decimals().into());
    let third_scale = pow_10(third_asset.decimals().into());
    let config = TestConfig { collateral_asset, debt_asset, collateral_scale, debt_scale, third_asset, third_scale };

    Env { singleton, extension, config, users }
}

pub fn test_interest_rate_config() -> InterestRateConfig {
    InterestRateConfig {
        min_target_utilization: 75_000,
        max_target_utilization: 85_000,
        target_utilization: 87_500,
        min_full_utilization_rate: 1582470460,
        max_full_utilization_rate: 32150205761,
        zero_utilization_rate: 158247046,
        rate_half_life: 172_800,
        target_rate_percent: 20 * PERCENT,
    }
}

pub fn create_pool(
    extension: IDefaultExtensionPOV2Dispatcher,
    config: TestConfig,
    owner: ContractAddress,
    interest_rate_config: Option<InterestRateConfig>,
) {
    let interest_rate_config = interest_rate_config.unwrap_or(test_interest_rate_config());

    let collateral_asset_params = AssetParams {
        asset: config.collateral_asset.contract_address,
        floor: SCALE / 10_000,
        initial_rate_accumulator: SCALE,
        initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
        max_utilization: SCALE,
        is_legacy: true,
        fee_rate: 0,
    };
    let debt_asset_params = AssetParams {
        asset: config.debt_asset.contract_address,
        floor: SCALE / 10_000,
        initial_rate_accumulator: SCALE,
        initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
        max_utilization: SCALE,
        is_legacy: false,
        fee_rate: 0,
    };
    let third_asset_params = AssetParams {
        asset: config.third_asset.contract_address,
        floor: SCALE / 10_000,
        initial_rate_accumulator: SCALE,
        initial_full_utilization_rate: (1582470460 + 32150205761) / 2,
        max_utilization: SCALE,
        is_legacy: false,
        fee_rate: 1 * PERCENT,
    };

    let collateral_asset_oracle_params = PragmaOracleParams {
        pragma_key: COLL_PRAGMA_KEY,
        timeout: 0,
        number_of_sources: 2,
        start_time_offset: 0,
        time_window: 0,
        aggregation_mode: AggregationMode::Median(()),
    };
    let debt_asset_oracle_params = PragmaOracleParams {
        pragma_key: DEBT_PRAGMA_KEY,
        timeout: 0,
        number_of_sources: 2,
        start_time_offset: 0,
        time_window: 0,
        aggregation_mode: AggregationMode::Median(()),
    };
    let third_asset_oracle_params = PragmaOracleParams {
        pragma_key: THIRD_PRAGMA_KEY,
        timeout: 0,
        number_of_sources: 2,
        start_time_offset: 0,
        time_window: 0,
        aggregation_mode: AggregationMode::Median(()),
    };

    // create ltv config for collateral and borrow assets
    let max_position_ltv_params_0 = LTVParams {
        collateral_asset_index: 1, debt_asset_index: 0, max_ltv: (80 * PERCENT).try_into().unwrap(),
    };
    let max_position_ltv_params_1 = LTVParams {
        collateral_asset_index: 0, debt_asset_index: 1, max_ltv: (80 * PERCENT).try_into().unwrap(),
    };
    let max_position_ltv_params_2 = LTVParams {
        collateral_asset_index: 0, debt_asset_index: 2, max_ltv: (85 * PERCENT).try_into().unwrap(),
    };
    let max_position_ltv_params_3 = LTVParams {
        collateral_asset_index: 2, debt_asset_index: 1, max_ltv: (85 * PERCENT).try_into().unwrap(),
    };

    let liquidation_params_0 = LiquidationParams {
        collateral_asset_index: 0, debt_asset_index: 1, liquidation_factor: 0,
    };
    let liquidation_params_1 = LiquidationParams {
        collateral_asset_index: 1, debt_asset_index: 0, liquidation_factor: 0,
    };
    let liquidation_params_2 = LiquidationParams {
        collateral_asset_index: 0, debt_asset_index: 2, liquidation_factor: 0,
    };
    let liquidation_params_3 = LiquidationParams {
        collateral_asset_index: 2, debt_asset_index: 1, liquidation_factor: 0,
    };

    let debt_cap_params_0 = DebtCapParams { collateral_asset_index: 0, debt_asset_index: 1, debt_cap: 0 };
    let debt_cap_params_1 = DebtCapParams { collateral_asset_index: 1, debt_asset_index: 0, debt_cap: 0 };
    let debt_cap_params_2 = DebtCapParams { collateral_asset_index: 0, debt_asset_index: 2, debt_cap: 0 };
    let debt_cap_params_3 = DebtCapParams { collateral_asset_index: 2, debt_asset_index: 1, debt_cap: 0 };

    let shutdown_params = ShutdownParams {
        recovery_period: DAY_IN_SECONDS, subscription_period: DAY_IN_SECONDS
    };

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension.create_pool('DefaultExtensionPOV2', FeeParams { fee_recipient: owner }, owner);

    // Add assets.
    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .add_asset(
            asset_params: collateral_asset_params,
            :interest_rate_config,
            pragma_oracle_params: collateral_asset_oracle_params,
        );

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .add_asset(
            asset_params: debt_asset_params, :interest_rate_config, pragma_oracle_params: debt_asset_oracle_params,
        );

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .add_asset(
            asset_params: third_asset_params, :interest_rate_config, pragma_oracle_params: third_asset_oracle_params,
        );

    // Set liquidation config.
    let collateral_asset = collateral_asset_params.asset;
    let debt_asset = debt_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_liquidation_config(
            :collateral_asset,
            :debt_asset,
            liquidation_config: LiquidationConfig { liquidation_factor: liquidation_params_0.liquidation_factor },
        );

    let collateral_asset = debt_asset_params.asset;
    let debt_asset = collateral_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_liquidation_config(
            :collateral_asset,
            :debt_asset,
            liquidation_config: LiquidationConfig { liquidation_factor: liquidation_params_1.liquidation_factor },
        );

    let collateral_asset = collateral_asset_params.asset;
    let debt_asset = third_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_liquidation_config(
            :collateral_asset,
            :debt_asset,
            liquidation_config: LiquidationConfig { liquidation_factor: liquidation_params_2.liquidation_factor },
        );

    let collateral_asset = third_asset_params.asset;
    let debt_asset = debt_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_liquidation_config(
            :collateral_asset,
            :debt_asset,
            liquidation_config: LiquidationConfig { liquidation_factor: liquidation_params_3.liquidation_factor },
        );

    // set the debt caps for each pair.
    let collateral_asset = collateral_asset_params.asset;
    let debt_asset = debt_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension.set_debt_cap(:collateral_asset, :debt_asset, debt_cap: debt_cap_params_0.debt_cap);

    let collateral_asset = debt_asset_params.asset;
    let debt_asset = collateral_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension.set_debt_cap(:collateral_asset, :debt_asset, debt_cap: debt_cap_params_1.debt_cap);

    let collateral_asset = collateral_asset_params.asset;
    let debt_asset = third_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension.set_debt_cap(:collateral_asset, :debt_asset, debt_cap: debt_cap_params_2.debt_cap);

    let collateral_asset = third_asset_params.asset;
    let debt_asset = debt_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension.set_debt_cap(:collateral_asset, :debt_asset, debt_cap: debt_cap_params_3.debt_cap);

    // Set lvt config.
    let collateral_asset = debt_asset_params.asset;
    let debt_asset = collateral_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_ltv_config(
            :collateral_asset, :debt_asset, ltv_config: LTVConfig { max_ltv: max_position_ltv_params_0.max_ltv },
        );

    let collateral_asset = collateral_asset_params.asset;
    let debt_asset = debt_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_ltv_config(
            :collateral_asset, :debt_asset, ltv_config: LTVConfig { max_ltv: max_position_ltv_params_1.max_ltv },
        );

    let collateral_asset = collateral_asset_params.asset;
    let debt_asset = third_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_ltv_config(
            :collateral_asset, :debt_asset, ltv_config: LTVConfig { max_ltv: max_position_ltv_params_2.max_ltv },
        );

    let collateral_asset = third_asset_params.asset;
    let debt_asset = debt_asset_params.asset;

    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension
        .set_ltv_config(
            :collateral_asset, :debt_asset, ltv_config: LTVConfig { max_ltv: max_position_ltv_params_3.max_ltv },
        );

    // set the shutdown config
    let ShutdownParams { recovery_period, subscription_period, .. } = shutdown_params;
    cheat_caller_address(extension.contract_address, owner, CheatSpan::TargetCalls(1));
    extension.set_shutdown_config(ShutdownConfig { recovery_period, subscription_period });

    assert!(extension.pool_name() == 'DefaultExtensionPOV2', "pool name not set");
}

pub fn setup_pool(
    oracle_address: ContractAddress,
    collateral_address: ContractAddress,
    debt_address: ContractAddress,
    third_address: ContractAddress,
    fund_borrower: bool,
    interest_rate_config: Option<InterestRateConfig>,
) -> (ISingletonV2Dispatcher, IDefaultExtensionPOV2Dispatcher, TestConfig, Users, LendingTerms) {
    let Env {
        singleton, extension, config, users, ..,
    } = setup_env(oracle_address, collateral_address, debt_address, third_address);

    create_pool(extension, config, users.owner, interest_rate_config);

    let TestConfig {
        collateral_asset, debt_asset, third_asset, collateral_scale, debt_scale, third_scale, ..,
    } = config;

    // lending terms
    let liquidity_to_deposit = debt_scale;
    let liquidity_to_deposit_third = third_scale;
    let collateral_to_deposit = collateral_scale;
    let debt_to_draw = debt_scale / 2; // 50% LTV
    let (asset_config, _) = singleton.asset_config(debt_asset.contract_address);
    let rate_accumulator = asset_config.last_rate_accumulator;
    let nominal_debt_to_draw = singleton.calculate_nominal_debt(debt_to_draw.into(), rate_accumulator, debt_scale);

    let terms = LendingTerms {
        liquidity_to_deposit,
        collateral_to_deposit,
        debt_to_draw,
        rate_accumulator,
        nominal_debt_to_draw,
        liquidity_to_deposit_third,
    };

    // fund borrower with collateral
    if fund_borrower {
        start_cheat_caller_address(collateral_asset.contract_address, users.lender);
        collateral_asset.transfer(users.borrower, collateral_to_deposit * 2);
        stop_cheat_caller_address(collateral_asset.contract_address);
    }

    start_cheat_caller_address(extension.contract_address, users.owner);
    extension.set_asset_parameter(collateral_asset.contract_address, 'floor', SCALE / 10_000);
    extension.set_asset_parameter(debt_asset.contract_address, 'floor', SCALE / 10_000);
    extension.set_asset_parameter(third_asset.contract_address, 'floor', SCALE / 10_000);
    extension.set_shutdown_mode_agent(get_contract_address());
    stop_cheat_caller_address(extension.contract_address);

    (singleton, extension, config, users, terms)
}

pub fn setup() -> (ISingletonV2Dispatcher, IDefaultExtensionPOV2Dispatcher, TestConfig, Users, LendingTerms) {
    setup_pool(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero(), true, Option::None)
}
