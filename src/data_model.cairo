use alexandria_math::i257::i257;
use starknet::ContractAddress;
use starknet::storage_access::StorePacking;
use vesu::math::pow_10;
use vesu::packing::{SHIFT_128, into_u123, split_128};
use vesu::units::SCALE;
use vesu::vendor::pragma::AggregationMode;

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct Position {
    pub collateral_shares: u256, // packed as u128 [SCALE]
    pub nominal_debt: u256 // packed as u123 [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct AssetConfig { //                                     | slot | packed | notes
    //                                                          | ---- | ------ | -----
    pub total_collateral_shares: u256, //       [SCALE]         | 1    | u128   |
    pub total_nominal_debt: u256, //            [SCALE]         | 1    | u123   |
    pub reserve: u256, //                       [asset scale]   | 2    | u128   |
    pub max_utilization: u256, //               [SCALE]         | 2    | u8     | constant percentage
    pub floor: u256, //                         [SCALE]         | 2    | u8     | constant decimals
    pub scale: u256, //                         [SCALE]         | 2    | u8     | constant decimals
    pub is_legacy: bool, //                                     | 2    | u8     | constant
    pub last_updated: u64, //                   [seconds]       | 3    | u32    |
    pub last_rate_accumulator: u256, //         [SCALE]         | 3    | u64    |
    pub last_full_utilization_rate: u256, //    [SCALE]         | 3    | u64    |
    pub fee_rate: u256, //                      [SCALE]         | 3    | u8     | percentage
    // tracks the number of unclaimed allocated shares (from each asset) that can be claimed by
    // `fee_recipient`.
    pub fee_shares: u256 //                     [SCALE]         | 4    | u128   |
}

pub fn assert_asset_config(asset_config: AssetConfig) {
    assert!(asset_config.scale <= pow_10(18), "scale-exceeded");
    assert!(asset_config.max_utilization <= SCALE, "max-utilization-exceeded");
    assert!(asset_config.last_rate_accumulator >= SCALE, "rate-accumulator-too-low");
    assert!(asset_config.fee_rate <= SCALE, "fee-rate-exceeded");
}

pub fn assert_asset_config_exists(asset_config: AssetConfig) {
    assert!(asset_config.scale != 0, "asset-config-nonexistent");
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct LTVConfig {
    pub max_ltv: u64 // [SCALE]
}

pub fn assert_ltv_config(ltv_config: LTVConfig) {
    assert!(ltv_config.max_ltv.into() <= SCALE, "invalid-ltv-config");
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub enum AmountDenomination {
    #[default]
    Native,
    Assets,
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub struct Amount {
    pub denomination: AmountDenomination,
    pub value: i257,
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub struct UnsignedAmount {
    pub denomination: AmountDenomination,
    pub value: u256,
}

#[derive(PartialEq, Copy, Drop, Serde, Default)]
pub struct AssetPrice {
    pub value: u256,
    pub is_valid: bool,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct AssetParams {
    pub asset: ContractAddress,
    pub floor: u256, // [SCALE]
    pub initial_rate_accumulator: u256, // [SCALE]
    pub initial_full_utilization_rate: u256, // [SCALE]
    pub max_utilization: u256, // [SCALE]
    pub is_legacy: bool,
    pub fee_rate: u256 // [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct LTVParams {
    pub collateral_asset_index: usize,
    pub debt_asset_index: usize,
    pub max_ltv: u64 // [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct DebtCapParams {
    pub collateral_asset_index: usize,
    pub debt_asset_index: usize,
    pub debt_cap: u256 // [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct ModifyPositionParams {
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub collateral: Amount,
    pub debt: Amount,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct LiquidatePositionParams {
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub receive_as_shares: bool,
    pub min_collateral_to_receive: u256,
    pub debt_to_repay: u256,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct UpdatePositionResponse {
    pub collateral_delta: i257, // [asset scale]
    pub collateral_shares_delta: i257, // [SCALE]
    pub debt_delta: i257, // [asset scale]
    pub nominal_debt_delta: i257, // [SCALE]
    pub bad_debt: u256 // [asset scale]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct ShutdownParams {
    pub recovery_period: u64, // [seconds]
    pub subscription_period: u64 // [seconds]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct LiquidationParams {
    pub collateral_asset_index: usize,
    pub debt_asset_index: usize,
    pub liquidation_factor: u64 // [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct FeeParams {
    pub fee_recipient: ContractAddress,
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct ShutdownConfig {
    pub recovery_period: u64, // [seconds]
    pub subscription_period: u64 // [seconds]
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct LiquidationConfig {
    pub liquidation_factor: u64 // [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct Pair {
    pub total_collateral_shares: u256, // packed as u128 [SCALE]
    pub total_nominal_debt: u256 // packed as u123 [SCALE]
}

impl PairPacking of StorePacking<Pair, felt252> {
    fn pack(value: Pair) -> felt252 {
        let total_collateral_shares: u128 = value
            .total_collateral_shares
            .try_into()
            .expect('pack-total_collateral-shares');
        let total_nominal_debt: u128 = value.total_nominal_debt.try_into().expect('pack-total_nominal-debt');
        let total_nominal_debt = into_u123(total_nominal_debt, 'pack-total_nominal-debt-u123');
        total_collateral_shares.into() + total_nominal_debt * SHIFT_128
    }

    fn unpack(value: felt252) -> Pair {
        let (total_nominal_debt, total_collateral_shares) = split_128(value.into());
        Pair { total_collateral_shares: total_collateral_shares.into(), total_nominal_debt: total_nominal_debt.into() }
    }
}

#[derive(PartialEq, Copy, Drop, Serde, Default, starknet::Store)]
pub enum ShutdownMode {
    #[default]
    None,
    Recovery,
    Subscription,
    Redemption,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct ShutdownStatus {
    pub shutdown_mode: ShutdownMode,
    pub violating: bool,
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct ShutdownState {
    // current set shutdown mode (overwrites the inferred shutdown mode)
    pub shutdown_mode: ShutdownMode,
    // timestamp at which the shutdown mode was last updated
    pub last_updated: u64,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct Context {
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub collateral_asset_config: AssetConfig,
    pub debt_asset_config: AssetConfig,
    pub collateral_asset_price: AssetPrice,
    pub debt_asset_price: AssetPrice,
    pub max_ltv: u64,
    pub user: ContractAddress,
    pub position: Position,
}
