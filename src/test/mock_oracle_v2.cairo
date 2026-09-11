use starknet::ContractAddress;
use vesu::vendor::chainlink::Round;
use vesu::vendor::pragma::{AggregationMode, DataType, PragmaPricesResponse};

#[starknet::interface]
pub trait IMockChainlinkFeed<TContractState> {
    fn latest_round_data(self: @TContractState) -> Round;
    fn decimals(self: @TContractState) -> u8;
    fn set_answer(ref self: TContractState, answer: u128);
    fn set_updated_at(ref self: TContractState, updated_at: u64);
    fn set_should_panic(ref self: TContractState, should_panic: bool);
}

/// Chainlink aggregator stand-in. `set_should_panic` turns every read into a revert, which is how
/// the failure isolation of the router is exercised.
#[starknet::contract]
mod MockChainlinkFeed {
    use starknet::get_block_timestamp;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::test::mock_oracle_v2::IMockChainlinkFeed;
    use vesu::vendor::chainlink::Round;

    #[storage]
    struct Storage {
        answer: u128,
        updated_at: u64,
        decimals: u8,
        should_panic: bool,
        updated_at_set: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, decimals: u8, answer: u128) {
        self.decimals.write(decimals);
        self.answer.write(answer);
    }

    #[abi(embed_v0)]
    impl MockChainlinkFeedImpl of IMockChainlinkFeed<ContractState> {
        fn latest_round_data(self: @ContractState) -> Round {
            assert!(!self.should_panic.read(), "mock-feed-panic");
            let updated_at = if self.updated_at_set.read() {
                self.updated_at.read()
            } else {
                get_block_timestamp()
            };
            Round { round_id: 1, answer: self.answer.read(), block_num: 1, started_at: updated_at, updated_at }
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }

        fn set_answer(ref self: ContractState, answer: u128) {
            self.answer.write(answer);
        }

        fn set_updated_at(ref self: ContractState, updated_at: u64) {
            self.updated_at.write(updated_at);
            self.updated_at_set.write(true);
        }

        fn set_should_panic(ref self: ContractState, should_panic: bool) {
            self.should_panic.write(should_panic);
        }
    }
}

#[starknet::interface]
pub trait IMockMalformedFeed<TContractState> {
    fn latest_round_data(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
}

/// Answers `latest_round_data` with a single felt instead of a `Round`, so the response cannot be
/// deserialized by the router.
#[starknet::contract]
mod MockMalformedFeed {
    use vesu::test::mock_oracle_v2::IMockMalformedFeed;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockMalformedFeedImpl of IMockMalformedFeed<ContractState> {
        fn latest_round_data(self: @ContractState) -> felt252 {
            42
        }

        fn decimals(self: @ContractState) -> u8 {
            8
        }
    }
}

#[starknet::interface]
pub trait IMockERC4626<TContractState> {
    fn convert_to_assets(self: @TContractState, shares: u256) -> u256;
    fn asset(self: @TContractState) -> ContractAddress;
    fn decimals(self: @TContractState) -> u8;
    /// amount of underlying returned for one whole share, in underlying units
    fn set_assets_per_share(ref self: TContractState, assets_per_share: u256);
    fn set_should_panic(ref self: TContractState, should_panic: bool);
}

/// ERC-4626 shaped wrapper. Share and underlying decimals are independent so that the decimals
/// handling of the `Scaled` route can be exercised with a mismatched pair.
#[starknet::contract]
mod MockERC4626 {
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::math::pow_10;
    use vesu::test::mock_oracle_v2::IMockERC4626;

    #[storage]
    struct Storage {
        asset: ContractAddress,
        decimals: u8,
        assets_per_share: u256,
        should_panic: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, asset: ContractAddress, decimals: u8, assets_per_share: u256) {
        self.asset.write(asset);
        self.decimals.write(decimals);
        self.assets_per_share.write(assets_per_share);
    }

    #[abi(embed_v0)]
    impl MockERC4626Impl of IMockERC4626<ContractState> {
        fn convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            assert!(!self.should_panic.read(), "mock-wrapper-panic");
            shares * self.assets_per_share.read() / pow_10(self.decimals.read().into())
        }

        fn asset(self: @ContractState) -> ContractAddress {
            self.asset.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }

        fn set_assets_per_share(ref self: ContractState, assets_per_share: u256) {
            self.assets_per_share.write(assets_per_share);
        }

        fn set_should_panic(ref self: ContractState, should_panic: bool) {
            self.should_panic.write(should_panic);
        }
    }
}

#[starknet::interface]
pub trait IMockEkuboOracle<TContractState> {
    fn get_price_x128_over_last(
        self: @TContractState, base_token: ContractAddress, quote_token: ContractAddress, period: u64,
    ) -> u256;
    fn get_earliest_observation_time(
        self: @TContractState, token_a: ContractAddress, token_b: ContractAddress,
    ) -> Option<u64>;
    fn set_price_x128(ref self: TContractState, period: u64, price_x128: u256);
    fn set_earliest_observation_time(ref self: TContractState, earliest_observation_time: u64);
    fn set_should_panic(ref self: TContractState, should_panic: bool);
}

/// Ekubo oracle extension stand-in. Prices are set per period so that a short window and the
/// configured window can disagree, which is what `spot_deviation` reports on.
#[starknet::contract]
mod MockEkuboOracle {
    use starknet::ContractAddress;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use vesu::test::mock_oracle_v2::IMockEkuboOracle;

    #[storage]
    struct Storage {
        prices_x128: Map<u64, u256>,
        earliest_observation_time: u64,
        should_panic: bool,
    }

    #[abi(embed_v0)]
    impl MockEkuboOracleImpl of IMockEkuboOracle<ContractState> {
        fn get_price_x128_over_last(
            self: @ContractState, base_token: ContractAddress, quote_token: ContractAddress, period: u64,
        ) -> u256 {
            assert!(!self.should_panic.read(), "mock-extension-panic");
            self.prices_x128.read(period)
        }

        /// Mirrors the deployed extension's `Option<u64>`. A stored zero stands in for `None`, so a
        /// test can express "this pair is not tracked" without a second setter.
        fn get_earliest_observation_time(
            self: @ContractState, token_a: ContractAddress, token_b: ContractAddress,
        ) -> Option<u64> {
            assert!(!self.should_panic.read(), "mock-extension-panic");
            let earliest = self.earliest_observation_time.read();
            if earliest == 0 {
                Option::None
            } else {
                Option::Some(earliest)
            }
        }

        fn set_price_x128(ref self: ContractState, period: u64, price_x128: u256) {
            self.prices_x128.write(period, price_x128);
        }

        fn set_earliest_observation_time(ref self: ContractState, earliest_observation_time: u64) {
            self.earliest_observation_time.write(earliest_observation_time);
        }

        fn set_should_panic(ref self: ContractState, should_panic: bool) {
            self.should_panic.write(should_panic);
        }
    }
}

#[starknet::interface]
pub trait IMockWideDecimalsPragma<TContractState> {
    fn get_data(self: @TContractState, data_type: DataType, aggregation_mode: AggregationMode) -> PragmaPricesResponse;
}

/// Pragma stand-in answering with a `decimals` outside `MAX_DECIMALS`. The value is supplied by the
/// source at read time and feeds `pow_10` directly, so it is the one exponent on the price path that
/// no configuration-time check can bound.
#[starknet::contract]
mod MockWideDecimalsPragma {
    use starknet::get_block_timestamp;
    use vesu::test::mock_oracle_v2::IMockWideDecimalsPragma;
    use vesu::vendor::pragma::{AggregationMode, DataType, PragmaPricesResponse};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockWideDecimalsPragmaImpl of IMockWideDecimalsPragma<ContractState> {
        fn get_data(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode,
        ) -> PragmaPricesResponse {
            PragmaPricesResponse {
                price: 1,
                decimals: 100,
                last_updated_timestamp: get_block_timestamp(),
                num_sources_aggregated: 5,
                expiration_timestamp: Option::None,
            }
        }
    }
}

/// Token that only answers `decimals`, with no supply arithmetic behind it, so a value outside
/// `MAX_DECIMALS` can be reported without the mock itself overflowing on `10^decimals`.
#[starknet::contract]
mod MockWideDecimalsToken {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::vendor::erc20::IERC20Metadata;

    #[storage]
    struct Storage {
        decimals: u8,
    }

    #[constructor]
    fn constructor(ref self: ContractState, decimals: u8) {
        self.decimals.write(decimals);
    }

    #[abi(embed_v0)]
    impl MockWideDecimalsTokenImpl of IERC20Metadata<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            'Wide'
        }

        fn symbol(self: @ContractState) -> felt252 {
            'WIDE'
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }
    }
}

#[starknet::interface]
pub trait IMockOracleV2Upgrade<TContractState> {
    fn upgrade_name(self: @TContractState) -> felt252;
    fn tag(self: @TContractState) -> felt252;
}

/// Upgrade target carrying the router's own `upgrade_name`, so the guard in `upgrade` passes and the
/// class swap can be observed through `tag`.
#[starknet::contract]
mod MockOracleV2Upgrade {
    use vesu::test::mock_oracle_v2::IMockOracleV2Upgrade;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockOracleV2UpgradeImpl of IMockOracleV2Upgrade<ContractState> {
        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu Oracle V2'
        }

        fn tag(self: @ContractState) -> felt252 {
            'MockOracleV2Upgrade'
        }
    }
}

/// EIC that rewrites `route_timelock`. The storage variable name is what fixes the slot, so the
/// library call lands on the router's own `route_timelock`.
#[starknet::contract]
mod MockOracleV2EIC {
    use starknet::storage::StoragePointerWriteAccess;
    use vesu::pool::IEIC;

    #[storage]
    struct Storage {
        route_timelock: u64,
    }

    #[abi(embed_v0)]
    impl MockOracleV2EICImpl of IEIC<ContractState> {
        fn eic_initialize(ref self: ContractState, data: Span<felt252>) {
            let new_timelock: u64 = (*data[0]).try_into().unwrap();
            self.route_timelock.write(new_timelock);
        }
    }
}

/// The ERC-4626 reads the router needs, minus `decimals` — that one comes from the ERC-20 metadata
/// impl, since both interfaces declare it and they share a selector.
#[starknet::interface]
pub trait IMockWrapperToken<TContractState> {
    fn convert_to_assets(self: @TContractState, shares: u256) -> u256;
    fn asset(self: @TContractState) -> ContractAddress;
    fn set_assets_per_share(ref self: TContractState, assets_per_share: u256);
}

/// An ERC-20 that is *also* ERC-4626 shaped, so it can be held by a `Pool` as collateral while the
/// router prices it through a `Scaled` route. `MockERC4626` cannot do this: it implements the 4626
/// reads but not the token interface, so a pool cannot take custody of it.
#[starknet::contract]
mod MockWrapperToken {
    use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::math::pow_10;
    use vesu::test::mock_oracle_v2::IMockWrapperToken;
    use vesu::vendor::erc20::IERC20Metadata;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        underlying: ContractAddress,
        decimals: u8,
        assets_per_share: u256,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        underlying: ContractAddress,
        decimals: u8,
        assets_per_share: u256,
        initial_supply: u256,
        recipient: ContractAddress,
    ) {
        self.underlying.write(underlying);
        self.decimals.write(decimals);
        self.assets_per_share.write(assets_per_share);
        self.erc20.mint(recipient, initial_supply);
    }

    #[abi(embed_v0)]
    impl ERC20MetadataImpl of IERC20Metadata<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            'Wrapper'
        }

        fn symbol(self: @ContractState) -> felt252 {
            'xMOCK'
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }
    }

    #[abi(embed_v0)]
    impl MockWrapperTokenImpl of IMockWrapperToken<ContractState> {
        fn convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            shares * self.assets_per_share.read() / pow_10(self.decimals.read().into())
        }

        fn asset(self: @ContractState) -> ContractAddress {
            self.underlying.read()
        }

        fn set_assets_per_share(ref self: ContractState, assets_per_share: u256) {
            self.assets_per_share.write(assets_per_share);
        }
    }
}
