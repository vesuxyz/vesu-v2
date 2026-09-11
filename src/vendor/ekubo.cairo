use starknet::ContractAddress;

/// Read surface of the Ekubo oracle extension, as deployed at
/// `0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f`.
///
/// `get_price_x128_over_last` returns the geometric mean price of `base_token` denominated in
/// `quote_token` over the last `period` seconds, in raw token units, scaled by 2^128.
///
/// `get_earliest_observation_time` returns `Option<u64>` — **not** `u64`. The deployed signature
/// takes an unordered pair (`token_a`, `token_b`) and answers `None` when the extension tracks no
/// observations for it. The distinction matters on the wire: `Some(t)` serialises as `[0, t]`, so
/// reading the response as a bare `u64` yields the variant tag `0` instead of `t` and makes every
/// route look like it has no history at all.
#[starknet::interface]
pub trait IEkuboOracle<TContractState> {
    fn get_price_x128_over_last(
        self: @TContractState, base_token: ContractAddress, quote_token: ContractAddress, period: u64,
    ) -> u256;
    fn get_earliest_observation_time(
        self: @TContractState, token_a: ContractAddress, token_b: ContractAddress,
    ) -> Option<u64>;
}
