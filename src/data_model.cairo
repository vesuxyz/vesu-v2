use alexandria_math::i257::i257;
use starknet::ContractAddress;
use vesu::units::SCALE;

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
    // `fee_recipient`
    pub fee_shares: u256 //                     [SCALE]         | 4    | u128   |
}

pub fn assert_asset_config(asset_config: AssetConfig) {
    assert!(asset_config.scale <= SCALE, "scale-exceeded");
    assert!(asset_config.max_utilization <= SCALE, "max-utilization-exceeded");
    assert!(asset_config.fee_rate <= SCALE, "fee-rate-exceeded");
}

pub fn assert_asset_config_exists(asset_config: AssetConfig) {
    assert!(asset_config.scale != 0, "asset-config-nonexistent");
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct PairConfig {
    pub max_ltv: u64, // [SCALE]
    pub liquidation_factor: u64, // [SCALE]
    pub debt_cap: u128 // [asset scale]
}

pub fn assert_pair_config(pair_config: PairConfig) {
    assert!(pair_config.max_ltv.into() <= SCALE, "max-ltv-exceeded");
    assert!(pair_config.liquidation_factor.into() <= SCALE, "liquidation-factor-exceeded");
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct PairParams {
    pub collateral_asset_index: usize,
    pub debt_asset_index: usize,
    pub max_ltv: u64, // [SCALE]
    pub liquidation_factor: u64, // [SCALE]
    pub debt_cap: u128 // [asset scale]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct AssetParams {
    pub asset: ContractAddress,
    pub floor: u256, // [SCALE]
    pub initial_full_utilization_rate: u256, // [SCALE]
    pub max_utilization: u256, // [SCALE]
    pub is_legacy: bool,
    pub fee_rate: u256 // [SCALE]
}

#[derive(PartialEq, Clone, Drop, Serde)]
pub struct VTokenParams {
    pub v_token_name: ByteArray,
    pub v_token_symbol: ByteArray,
    pub debt_asset: ContractAddress,
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
pub struct Pair {
    pub total_collateral_shares: u256, // packed as u128 [SCALE]
    pub total_nominal_debt: u256 // packed as u123 [SCALE]
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
