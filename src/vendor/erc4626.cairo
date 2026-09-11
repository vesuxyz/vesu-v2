use starknet::ContractAddress;

/// Minimal ERC-4626 surface used to derive a conversion rate for a yield bearing wrapper.
/// `convert_to_assets` is used deliberately instead of `preview_redeem`, which may include
/// withdrawal fees or queue effects and is therefore not a pure exchange rate.
#[starknet::interface]
pub trait IERC4626<TContractState> {
    fn convert_to_assets(self: @TContractState, shares: u256) -> u256;
    fn asset(self: @TContractState) -> ContractAddress;
    fn decimals(self: @TContractState) -> u8;
}
