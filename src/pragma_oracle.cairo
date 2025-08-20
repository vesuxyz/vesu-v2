use vesu::vendor::pragma::AggregationMode;

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct OracleConfig {
    pub pragma_key: felt252,
    pub timeout: u64, // [seconds]
    pub number_of_sources: u32, // [0, 255]
    pub start_time_offset: u64, // [seconds]
    pub time_window: u64, // [seconds]
    pub aggregation_mode: AggregationMode,
}

pub fn assert_oracle_config(oracle_config: OracleConfig) {
    assert!(oracle_config.pragma_key != 0, "pragma-key-must-be-set");
    assert!(
        oracle_config.time_window <= oracle_config.start_time_offset, "time-window-must-be-less-than-start-time-offset",
    );
}

#[starknet::component]
pub mod pragma_oracle_component {
    use core::num::traits::Zero;
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use vesu::math::pow_10;
    use vesu::pragma_oracle::{OracleConfig, assert_oracle_config};
    use vesu::units::SCALE;
    use vesu::vendor::pragma::{
        AggregationMode, DataType, IPragmaABIDispatcher, IPragmaABIDispatcherTrait, ISummaryStatsABIDispatcher,
        ISummaryStatsABIDispatcherTrait,
    };

    #[storage]
    pub struct Storage {
        pub oracle_address: ContractAddress,
        pub summary_address: ContractAddress,
        // asset -> oracle configuration
        pub oracle_configs: Map<ContractAddress, OracleConfig>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetOracleConfig {
        asset: ContractAddress,
        oracle_config: OracleConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetOracleParameter {
        asset: ContractAddress,
        parameter: felt252,
        value: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        SetOracleConfig: SetOracleConfig,
        SetOracleParameter: SetOracleParameter,
    }

    #[generate_trait]
    pub impl PragmaOracleTrait<TContractState, +HasComponent<TContractState>> of Trait<TContractState> {
        /// Sets the address of the summary contract
        /// # Arguments
        /// * `summary_address` - address of the summary contract
        fn set_summary_address(ref self: ComponentState<TContractState>, summary_address: ContractAddress) {
            self.summary_address.write(summary_address);
        }

        /// Returns the address of the summary contract
        /// # Returns
        /// * `summary_address` - address of the summary contract
        fn summary_address(self: @ComponentState<TContractState>) -> ContractAddress {
            self.summary_address.read()
        }

        /// Sets the address of the pragma oracle contract
        /// # Arguments
        /// * `oracle_address` - address of the pragma oracle contract
        fn set_oracle(ref self: ComponentState<TContractState>, oracle_address: ContractAddress) {
            assert!(self.oracle_address.read().is_zero(), "oracle-already-initialized");
            self.oracle_address.write(oracle_address);
        }

        /// Returns the address of the pragma oracle contract
        /// # Returns
        /// * `oracle_address` - address of the pragma oracle contract
        fn oracle_address(self: @ComponentState<TContractState>) -> ContractAddress {
            self.oracle_address.read()
        }

        /// Returns the current price for an asset and the validity status of the price.
        /// The price can be invalid if price is too old (stale) or if the number of price sources is too low.
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `price` - current price of the asset
        /// * `valid` - whether the price is valid
        fn price(self: @ComponentState<TContractState>, asset: ContractAddress) -> (u256, bool) {
            let OracleConfig {
                pragma_key, timeout, number_of_sources, start_time_offset, time_window, aggregation_mode,
            } = self.oracle_configs.read(asset);
            let dispatcher = IPragmaABIDispatcher { contract_address: self.oracle_address.read() };
            let response = dispatcher.get_data(DataType::SpotEntry(pragma_key), aggregation_mode);

            // calculate the twap if start_time_offset and time_window are set
            let price = if start_time_offset == 0 || time_window == 0 {
                u256_mul_div(response.price.into(), SCALE, pow_10(response.decimals.into()), Rounding::Floor)
            } else {
                let summary = ISummaryStatsABIDispatcher { contract_address: self.summary_address.read() };
                let (value, decimals) = summary
                    .calculate_twap(
                        DataType::SpotEntry(pragma_key),
                        aggregation_mode,
                        time_window,
                        get_block_timestamp() - start_time_offset,
                    );
                u256_mul_div(value.into(), SCALE, pow_10(decimals.into()), Rounding::Floor)
            };

            // ensure that price is not stale and that the number of sources is sufficient
            let time_delta = if response.last_updated_timestamp >= get_block_timestamp() {
                0
            } else {
                get_block_timestamp() - response.last_updated_timestamp
            };
            let valid = (timeout == 0 || time_delta <= timeout)
                && (number_of_sources == 0 || number_of_sources <= response.num_sources_aggregated);

            (price, valid)
        }

        /// Sets the oracle configuration for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `oracle_config` - oracle configuration
        fn set_oracle_config(
            ref self: ComponentState<TContractState>, asset: ContractAddress, oracle_config: OracleConfig,
        ) {
            let OracleConfig { pragma_key, .. } = self.oracle_configs.read(asset);
            assert!(pragma_key == 0, "oracle-config-already-set");
            assert_oracle_config(oracle_config);

            self.oracle_configs.write(asset, oracle_config);

            self.emit(SetOracleConfig { asset, oracle_config });
        }

        /// Sets a parameter for a given oracle configuration of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_oracle_parameter(
            ref self: ComponentState<TContractState>, asset: ContractAddress, parameter: felt252, value: felt252,
        ) {
            let mut oracle_config: OracleConfig = self.oracle_configs.read(asset);
            assert!(oracle_config.pragma_key != 0, "oracle-config-not-set");

            if parameter == 'pragma_key' {
                oracle_config.pragma_key = value;
            } else if parameter == 'timeout' {
                oracle_config.timeout = value.try_into().unwrap();
            } else if parameter == 'number_of_sources' {
                oracle_config.number_of_sources = value.try_into().unwrap();
            } else if parameter == 'start_time_offset' {
                oracle_config.start_time_offset = value.try_into().unwrap();
            } else if parameter == 'time_window' {
                oracle_config.time_window = value.try_into().unwrap();
            } else if parameter == 'aggregation_mode' {
                if value == 'Median' {
                    oracle_config.aggregation_mode = AggregationMode::Median;
                } else if value == 'Mean' {
                    oracle_config.aggregation_mode = AggregationMode::Mean;
                } else {
                    assert!(false, "invalid-aggregation-mode");
                }
            } else {
                assert!(false, "invalid-oracle-parameter");
            }

            assert_oracle_config(oracle_config);
            self.oracle_configs.write(asset, oracle_config);

            self.emit(SetOracleParameter { asset, parameter, value });
        }
    }
}
