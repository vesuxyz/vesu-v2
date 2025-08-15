use alexandria_math::i257::i257;
use starknet::ContractAddress;
use vesu::data_model::Context;

#[starknet::interface]
pub trait IExtension<TContractState> {
    fn singleton(self: @TContractState) -> ContractAddress;
    fn after_modify_position(
        ref self: TContractState,
        context: Context,
        collateral_delta: i257,
        collateral_shares_delta: i257,
        debt_delta: i257,
        nominal_debt_delta: i257,
        caller: ContractAddress,
    ) -> bool;
    fn before_liquidate_position(
        ref self: TContractState,
        context: Context,
        min_collateral_to_receive: u256,
        debt_to_repay: u256,
        caller: ContractAddress,
    ) -> (u256, u256, u256);
    fn after_liquidate_position(
        ref self: TContractState,
        context: Context,
        collateral_delta: i257,
        collateral_shares_delta: i257,
        debt_delta: i257,
        nominal_debt_delta: i257,
        bad_debt: u256,
        caller: ContractAddress,
    ) -> bool;
}
