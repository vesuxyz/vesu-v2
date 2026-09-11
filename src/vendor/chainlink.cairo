/// Round data as returned by the Chainlink aggregator proxies deployed on Starknet.
/// The field order is part of the ABI — see `OracleV2` for how a mismatch is handled: the
/// deserialization fails and the price is reported invalid rather than reverting.
#[derive(Copy, Drop, Serde, PartialEq)]
pub struct Round {
    pub round_id: felt252,
    pub answer: u128,
    pub block_num: u64,
    pub started_at: u64,
    pub updated_at: u64,
}

#[starknet::interface]
pub trait IChainlinkAggregator<TContractState> {
    fn latest_round_data(self: @TContractState) -> Round;
    fn decimals(self: @TContractState) -> u8;
}
