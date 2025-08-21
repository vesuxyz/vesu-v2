use starknet::{ClassHash, ContractAddress};
use vesu::data_model::AssetPrice;
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

#[starknet::interface]
pub trait IOracle<TContractState> {
    fn pragma_oracle(self: @TContractState) -> ContractAddress;
    fn pragma_summary(self: @TContractState) -> ContractAddress;
    fn oracle_config(self: @TContractState, asset: ContractAddress) -> OracleConfig;
    fn add_asset(ref self: TContractState, asset: ContractAddress, oracle_config: OracleConfig);
    fn set_oracle_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: felt252);
    fn price(self: @TContractState, asset: ContractAddress) -> AssetPrice;

    fn curator(self: @TContractState) -> ContractAddress;
    fn pending_curator(self: @TContractState) -> ContractAddress;
    fn nominate_curator(ref self: TContractState, pending_curator: ContractAddress);
    fn accept_curator_ownership(ref self: TContractState);

    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(
        ref self: TContractState,
        new_implementation: ClassHash,
        eic_implementation_data: Option<(ClassHash, Span<felt252>)>,
    );
}

#[starknet::contract]
mod Oracle {
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use vesu::data_model::AssetPrice;
    use vesu::math::pow_10;
    use vesu::oracle::{IOracle, IOracleDispatcher, IOracleDispatcherTrait, OracleConfig, assert_oracle_config};
    use vesu::packing::{AssetConfigPacking, PositionPacking};
    use vesu::pool::{IEICDispatcherTrait, IEICLibraryDispatcher};
    use vesu::units::SCALE;
    use vesu::vendor::pragma::{
        AggregationMode, DataType, IPragmaABIDispatcher, IPragmaABIDispatcherTrait, ISummaryStatsABIDispatcher,
        ISummaryStatsABIDispatcherTrait,
    };

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        // The address of the pragma oracle contract
        oracle_address: ContractAddress,
        // The address of the pragma summary contract
        summary_address: ContractAddress,
        // asset -> oracle configuration
        oracle_configs: Map<ContractAddress, OracleConfig>,
        // The owner of the pool
        curator: ContractAddress,
        // The pending curator
        pending_curator: ContractAddress,
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

    #[derive(Drop, starknet::Event)]
    struct SetCurator {
        #[key]
        curator: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct NominateCurator {
        #[key]
        pending_curator: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ContractUpgraded {
        new_implementation: ClassHash,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        SetOracleConfig: SetOracleConfig,
        SetOracleParameter: SetOracleParameter,
        ContractUpgraded: ContractUpgraded,
        SetCurator: SetCurator,
        NominateCurator: NominateCurator,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        curator: ContractAddress,
        oracle_address: ContractAddress,
        summary_address: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        assert!(curator.is_non_zero(), "invalid-zero-curator");
        self.curator.write(curator);
        self.pending_curator.write(Zero::zero());

        self.oracle_address.write(oracle_address);
        self.summary_address.write(summary_address);
    }

    #[abi(embed_v0)]
    impl OracleV2Impl of IOracle<ContractState> {
        /// Returns the address of the pragma oracle contract
        /// # Returns
        /// * `oracle_address` - address of the pragma oracle contract
        fn pragma_oracle(self: @ContractState) -> ContractAddress {
            self.oracle_address.read()
        }

        /// Returns the address of the pragma summary contract
        /// # Returns
        /// * `summary_address` - address of the pragma summary contract
        fn pragma_summary(self: @ContractState) -> ContractAddress {
            self.summary_address.read()
        }

        /// Returns the oracle configuration for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `oracle_config` - oracle configuration
        fn oracle_config(self: @ContractState, asset: ContractAddress) -> OracleConfig {
            self.oracle_configs.read(asset)
        }

        /// Sets oracle config for an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `oracle_config` - oracle configuration
        fn add_asset(ref self: ContractState, asset: ContractAddress, oracle_config: OracleConfig) {
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            assert!(self.oracle_configs.read(asset).pragma_key.is_zero(), "oracle-already-set");

            assert_oracle_config(oracle_config);

            self.oracle_configs.write(asset, oracle_config);

            self.emit(SetOracleConfig { asset, oracle_config });
        }

        /// Sets a parameter for a given oracle configuration of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_oracle_parameter(ref self: ContractState, asset: ContractAddress, parameter: felt252, value: felt252) {
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");

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

        /// Returns the current price for an asset and the validity status of the price.
        /// The price can be invalid if price is too old (stale) or if the number of price sources is too low.
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `AssetPrice` - latest price of the asset and its validity
        fn price(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            let OracleConfig {
                pragma_key, timeout, number_of_sources, start_time_offset, time_window, aggregation_mode,
            } = self.oracle_configs.read(asset);

            assert!(pragma_key.is_non_zero(), "oracle-price-invalid");

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
                && (number_of_sources <= response.num_sources_aggregated)
                && (response.price.into() != 0);

            AssetPrice { value: price, is_valid: valid }
        }

        /// Returns the address of the curator
        /// # Returns
        /// * `curator` - address of the curator
        fn curator(self: @ContractState) -> ContractAddress {
            self.curator.read()
        }

        /// Returns the address of the pending curator
        /// # Returns
        /// * `pending_curator` - address of the pending curator
        fn pending_curator(self: @ContractState) -> ContractAddress {
            self.pending_curator.read()
        }

        /// Initiate transferring ownership of the pool.
        /// The nominated curator should invoke `accept_curator_ownership` to complete the transfer.
        /// At that point, the original curator will be removed and replaced with the nominated curator.
        /// # Arguments
        /// * `curator` - address of the new curator
        fn nominate_curator(ref self: ContractState, pending_curator: ContractAddress) {
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");

            self.pending_curator.write(pending_curator);
            self.emit(NominateCurator { pending_curator });
        }

        /// Accept the curator address.
        /// At this point, the original curator will be removed and replaced with the nominated curator.
        fn accept_curator_ownership(ref self: ContractState) {
            let new_curator = self.pending_curator.read();
            assert!(get_caller_address() == new_curator, "caller-not-new-curator");
            assert!(new_curator.is_non_zero(), "invalid-zero-curator-address");

            self.pending_curator.write(Zero::zero());
            self.curator.write(new_curator);
            self.emit(SetCurator { curator: new_curator });
        }

        /// Returns the name of the contract
        /// # Returns
        /// * `name` - the name of the contract
        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu Oracle'
        }

        /// Upgrades the contract to a new implementation
        /// # Arguments
        /// * `new_implementation` - the new implementation class hash
        /// * `eic_implementation_data` - the (optional) eic implementation class hash and the calldata
        /// to pass to the eic `eic_initialize` function
        fn upgrade(
            ref self: ContractState,
            new_implementation: ClassHash,
            eic_implementation_data: Option<(ClassHash, Span<felt252>)>,
        ) {
            self.ownable.assert_only_owner();

            if let Some((eic_implementation, eic_data)) = eic_implementation_data {
                IEICLibraryDispatcher { class_hash: eic_implementation }.eic_initialize(eic_data);
            }
            replace_class_syscall(new_implementation).unwrap_syscall();
            // Check to prevent mistakes when upgrading the contract
            let new_name = IOracleDispatcher { contract_address: get_contract_address() }.upgrade_name();
            assert(new_name == self.upgrade_name(), 'invalid upgrade name');
            self.emit(ContractUpgraded { new_implementation });
        }
    }
}
