use vesu::vendor::pragma::{AggregationMode, DataType, PragmaPricesResponse};

#[starknet::interface]
pub trait IMockPragmaSummary<TContractState> {
    fn calculate_twap(
        self: @TContractState, data_type: DataType, aggregation_mode: AggregationMode, time: u64, start_time: u64,
    ) -> (u128, u32);
    fn set_twap(ref self: TContractState, key: felt252, twap: u128, decimals: u32);
}

#[starknet::contract]
mod MockPragmaSummary {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use vesu::test::mock_oracle::IMockPragmaSummary;
    use vesu::vendor::pragma::{AggregationMode, DataType};

    #[storage]
    struct Storage {
        twaps: Map<felt252, u128>,
        decimals: u32,
    }

    #[abi(embed_v0)]
    impl MockPragmaSummaryImpl of IMockPragmaSummary<ContractState> {
        fn calculate_twap(
            self: @ContractState, data_type: DataType, aggregation_mode: AggregationMode, time: u64, start_time: u64,
        ) -> (u128, u32) {
            match data_type {
                DataType::SpotEntry(key) => { (self.twaps.read(key), self.decimals.read()) },
                DataType::FutureEntry(_) => { (0, 0) },
                DataType::GenericEntry(_) => { (0, 0) },
            }
        }

        fn set_twap(ref self: ContractState, key: felt252, twap: u128, decimals: u32) {
            self.twaps.write(key, twap);
            self.decimals.write(decimals);
        }
    }
}

#[starknet::interface]
pub trait IMockPragmaOracle<TContractState> {
    fn get_data(
        ref self: TContractState, data_type: DataType, aggregation_mode: AggregationMode,
    ) -> PragmaPricesResponse;
    fn get_data_median(ref self: TContractState, data_type: DataType) -> PragmaPricesResponse;
    fn get_num_sources_aggregated(ref self: TContractState, key: felt252) -> u32;
    fn get_last_updated_timestamp(ref self: TContractState, key: felt252) -> u64;
    fn set_price(ref self: TContractState, key: felt252, price: u128);
    fn set_num_sources_aggregated(ref self: TContractState, key: felt252, num_sources_aggregated: u32);
    fn set_last_updated_timestamp(ref self: TContractState, key: felt252, last_updated_timestamp: u64);
}

#[starknet::contract]
mod MockPragmaOracle {
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{get_block_timestamp, get_caller_address};
    use vesu::test::mock_oracle::IMockPragmaOracle;
    use vesu::vendor::pragma::{AggregationMode, DataType, PragmaPricesResponse};

    #[derive(Copy, Drop, Serde)]
    struct BaseEntry {
        timestamp: u64,
        source: felt252,
        publisher: felt252,
    }

    #[derive(Copy, Drop, Serde)]
    struct SpotEntry {
        base: BaseEntry,
        price: u128,
        pair_id: felt252,
        volume: u128,
    }

    #[storage]
    struct Storage {
        prices: Map<felt252, u128>,
        num_sources_aggregated: Map<felt252, u32>,
        last_updated_timestamp: Map<felt252, u64>,
    }

    #[derive(Drop, starknet::Event)]
    #[event]
    enum Event {
        SubmittedSpotEntry: SubmittedSpotEntry,
    }

    #[derive(Drop, starknet::Event)]
    struct SubmittedSpotEntry {
        spot_entry: SpotEntry,
    }

    #[abi(embed_v0)]
    impl MockPragmaOracleImpl of IMockPragmaOracle<ContractState> {
        fn get_num_sources_aggregated(ref self: ContractState, key: felt252) -> u32 {
            let num_sources_aggregated = self.num_sources_aggregated.read(key);
            if num_sources_aggregated == 0 {
                2
            } else {
                num_sources_aggregated
            }
        }

        fn get_last_updated_timestamp(ref self: ContractState, key: felt252) -> u64 {
            let last_updated_timestamp = self.last_updated_timestamp.read(key);
            if last_updated_timestamp == 0 {
                get_block_timestamp()
            } else {
                last_updated_timestamp
            }
        }

        fn get_data(
            ref self: ContractState, data_type: DataType, aggregation_mode: AggregationMode,
        ) -> PragmaPricesResponse {
            self.get_data_median(data_type)
        }

        fn get_data_median(ref self: ContractState, data_type: DataType) -> PragmaPricesResponse {
            match data_type {
                DataType::SpotEntry(key) => {
                    PragmaPricesResponse {
                        price: self.prices.read(key),
                        decimals: 18,
                        last_updated_timestamp: self.get_last_updated_timestamp(key),
                        num_sources_aggregated: self.get_num_sources_aggregated(key),
                        expiration_timestamp: Option::None,
                    }
                },
                DataType::FutureEntry(_) => {
                    PragmaPricesResponse {
                        price: 0,
                        decimals: 0,
                        last_updated_timestamp: 0,
                        num_sources_aggregated: 0,
                        expiration_timestamp: Option::None,
                    }
                },
                DataType::GenericEntry(_) => {
                    PragmaPricesResponse {
                        price: 0,
                        decimals: 0,
                        last_updated_timestamp: 0,
                        num_sources_aggregated: 0,
                        expiration_timestamp: Option::None,
                    }
                },
            }
        }

        fn set_price(ref self: ContractState, key: felt252, price: u128) {
            self.prices.write(key, price);
            self
                .emit(
                    Event::SubmittedSpotEntry(
                        SubmittedSpotEntry {
                            spot_entry: SpotEntry {
                                base: BaseEntry {
                                    timestamp: get_block_timestamp(),
                                    source: key,
                                    publisher: get_caller_address().into(),
                                },
                                price: price,
                                pair_id: 0,
                                volume: 0,
                            },
                        },
                    ),
                );
        }

        fn set_num_sources_aggregated(ref self: ContractState, key: felt252, num_sources_aggregated: u32) {
            self.num_sources_aggregated.write(key, num_sources_aggregated);
        }

        fn set_last_updated_timestamp(ref self: ContractState, key: felt252, last_updated_timestamp: u64) {
            self.last_updated_timestamp.write(key, last_updated_timestamp);
        }
    }
}
