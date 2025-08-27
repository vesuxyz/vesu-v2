use core::traits::DivRem;
use starknet::storage_access::StorePacking;
use vesu::data_model::{AssetConfig, Pair, PairConfig, Position, assert_asset_config_exists};
use vesu::math::{log_10_or_0, pow_10_or_0};
use vesu::units::PERCENT;

pub impl PositionPacking of StorePacking<Position, felt252> {
    fn pack(value: Position) -> felt252 {
        let collateral_shares: u128 = value.collateral_shares.try_into().expect('pack-collateral-shares');
        let nominal_debt: u128 = value.nominal_debt.try_into().expect('pack-nominal-debt');
        let nominal_debt = into_u123(nominal_debt, 'pack-nominal-debt-u123');
        collateral_shares.into() + nominal_debt * SHIFT_128
    }

    fn unpack(value: felt252) -> Position {
        let (nominal_debt, collateral_shares) = split_128(value.into());
        Position { collateral_shares: collateral_shares.into(), nominal_debt: nominal_debt.into() }
    }
}

pub impl PairPacking of StorePacking<Pair, felt252> {
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

pub impl AssetConfigPacking of StorePacking<AssetConfig, (felt252, felt252, felt252, felt252)> {
    fn pack(value: AssetConfig) -> (felt252, felt252, felt252, felt252) {
        // slot 1
        let total_collateral_shares: u128 = value
            .total_collateral_shares
            .try_into()
            .expect('pack-total-collateral-shares');
        let total_nominal_debt: u128 = value.total_nominal_debt.try_into().expect('pack-total-nominal-debt');
        let total_nominal_debt = into_u123(total_nominal_debt, 'pack-total-nominal-debt-u123');
        let slot1 = total_collateral_shares.into() + total_nominal_debt * SHIFT_128;

        // slot 2
        let reserve: u128 = value.reserve.try_into().expect('pack-reserve');
        let max_utilization: u8 = (value.max_utilization / PERCENT).try_into().expect('pack-max-utilization');
        let floor_decimals: u8 = log_10_or_0(value.floor);
        let scale_decimals: u8 = log_10_or_0(value.scale);
        let slot2 = reserve.into()
            + max_utilization.into() * SHIFT_128
            + floor_decimals.into() * SHIFT_128 * SHIFT_8
            + scale_decimals.into() * SHIFT_128 * SHIFT_8 * SHIFT_8
            + value.is_legacy.into() * SHIFT_128 * SHIFT_8 * SHIFT_8 * SHIFT_8;

        // slot 3
        let last_updated: u32 = value.last_updated.try_into().expect('pack-last-updated');
        let last_rate_accumulator: u64 = value.last_rate_accumulator.try_into().expect('pack-last-rate-accumulator');
        let last_full_utilization_rate: u64 = value
            .last_full_utilization_rate
            .try_into()
            .expect('pack-last-full-utilization-rate');
        let fee_rate: u8 = (value.fee_rate / PERCENT).try_into().expect('pack-fee-rate');
        let slot3 = last_updated.into()
            + last_rate_accumulator.into() * SHIFT_32
            + last_full_utilization_rate.into() * SHIFT_32 * SHIFT_64
            + fee_rate.into() * SHIFT_32 * SHIFT_64 * SHIFT_64;

        // slot 4
        let fee_shares: u128 = value.fee_shares.try_into().expect('pack-fee-shares');
        let slot4 = fee_shares.into();

        (slot1, slot2, slot3, slot4)
    }

    fn unpack(value: (felt252, felt252, felt252, felt252)) -> AssetConfig {
        let (slot1, slot2, slot3, slot4) = value;

        // slot 1
        let (total_nominal_debt, total_collateral_shares) = split_128(slot1.into());

        // slot 2
        let (rest, reserve) = split_128(slot2.into());
        let (rest, max_utilization) = split_8(rest.into());
        let (rest, floor_decimals) = split_8(rest);
        let (rest, scale_decimals) = split_8(rest);
        let (rest, is_legacy) = split_8(rest);
        assert!(rest == 0, "asset-config-slot2-excess-data");

        // slot 3
        let (rest, last_updated) = split_32(slot3.into());
        let (rest, last_rate_accumulator) = split_64(rest);
        let (rest, last_full_utilization_rate) = split_64(rest);
        let (rest, fee_rate) = split_8(rest);
        assert!(rest == 0, "asset-config-slot3-excess-data");

        // slot 4
        let (rest, fee_shares) = split_128(slot4.into());
        assert!(rest == 0, "asset-config-slot4-excess-data");

        AssetConfig {
            total_collateral_shares: total_collateral_shares.into(),
            total_nominal_debt: total_nominal_debt.into(),
            reserve: reserve.into(),
            max_utilization: max_utilization.into() * PERCENT,
            floor: pow_10_or_0(floor_decimals.into()),
            scale: pow_10_or_0(scale_decimals.into()),
            is_legacy: is_legacy != 0,
            last_updated: last_updated.into(),
            last_rate_accumulator: last_rate_accumulator.into(),
            last_full_utilization_rate: last_full_utilization_rate.into(),
            fee_rate: fee_rate.into() * PERCENT,
            fee_shares: fee_shares.into(),
        }
    }
}

pub fn assert_storable_asset_config(asset_config: AssetConfig) {
    assert_asset_config_exists(asset_config);
    let packed = AssetConfigPacking::pack(asset_config);
    let unpacked = AssetConfigPacking::unpack(packed);
    assert!(asset_config.max_utilization == unpacked.max_utilization, "max-utilization-precision-loss");
    assert!(asset_config.floor == unpacked.floor, "floor-precision-loss");
    assert!(asset_config.scale == unpacked.scale, "scale-precision-loss");
    assert!(asset_config.fee_rate == unpacked.fee_rate, "fee-rate-precision-loss");
}

pub impl PairConfigPacking of StorePacking<PairConfig, felt252> {
    fn pack(value: PairConfig) -> felt252 {
        let max_ltv: u64 = value.max_ltv.try_into().expect('pack-max-ltv');
        let liquidation_factor: u64 = value.liquidation_factor.try_into().expect('pack-liquidation-factor');
        let debt_cap: u128 = value.debt_cap.try_into().expect('pack-debt-cap');
        let debt_cap = into_u123(debt_cap, 'pack-debt-cap-u123');
        max_ltv.into() + liquidation_factor.into() * SHIFT_64 + debt_cap.into() * SHIFT_64 * SHIFT_64
    }

    fn unpack(value: felt252) -> PairConfig {
        let (rest, max_ltv) = split_64(value.into());
        let (rest, liquidation_factor) = split_64(rest);
        let (rest, debt_cap) = split_128(rest);
        assert!(rest == 0, "pair-config-excess-data");
        PairConfig { max_ltv: max_ltv.into(), liquidation_factor: liquidation_factor.into(), debt_cap: debt_cap.into() }
    }
}

pub fn assert_storable_pair_config(pair_config: PairConfig) {
    let packed = PairConfigPacking::pack(pair_config);
    let unpacked = PairConfigPacking::unpack(packed);
    assert!(pair_config.max_ltv == unpacked.max_ltv, "max-ltv-precision-loss");
    assert!(pair_config.liquidation_factor == unpacked.liquidation_factor, "liquidation-factor-precision-loss");
    assert!(pair_config.debt_cap == unpacked.debt_cap, "debt-cap-precision-loss");
}

pub const SHIFT_8: felt252 = 0x100;
pub const SHIFT_16: felt252 = 0x10000;
pub const SHIFT_32: felt252 = 0x100000000;
pub const SHIFT_64: felt252 = 0x10000000000000000;
pub const SHIFT_128: felt252 = 0x100000000000000000000000000000000;

pub fn split_8(value: u256) -> (u256, u8) {
    let shift: u256 = SHIFT_8.into();
    let (rest, first) = DivRem::div_rem(value, shift.try_into().unwrap());
    (rest, first.try_into().unwrap())
}

pub fn split_16(value: u256) -> (u256, u16) {
    let shift: u256 = SHIFT_16.into();
    let (rest, first) = DivRem::div_rem(value, shift.try_into().unwrap());
    (rest, first.try_into().unwrap())
}

pub fn split_32(value: u256) -> (u256, u32) {
    let shift: u256 = SHIFT_32.into();
    let (rest, first) = DivRem::div_rem(value, shift.try_into().unwrap());
    (rest, first.try_into().unwrap())
}

pub fn split_64(value: u256) -> (u256, u64) {
    let shift: u256 = SHIFT_64.into();
    let (rest, first) = DivRem::div_rem(value, shift.try_into().unwrap());
    (rest, first.try_into().unwrap())
}

pub fn split_128(value: u256) -> (u128, u128) {
    let shift: u256 = SHIFT_128.into();
    let (rest, first) = DivRem::div_rem(value, shift.try_into().unwrap());
    (rest.try_into().unwrap(), first.try_into().unwrap())
}

pub const U123_BOUND: u128 = 0x8000000000000000000000000000000;

pub fn into_u123(value: u128, err: felt252) -> felt252 {
    assert(value < U123_BOUND, err);
    value.into()
}
