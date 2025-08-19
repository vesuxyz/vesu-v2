use starknet::{ClassHash, ContractAddress};
use vesu::data_model::AssetPrice;
use vesu::extension::components::pragma_oracle::OracleConfig;

#[starknet::interface]
pub trait IOracle<TContractState> {
    fn pragma_oracle(self: @TContractState) -> ContractAddress;
    fn pragma_summary(self: @TContractState) -> ContractAddress;
    fn oracle_config(self: @TContractState, asset: ContractAddress) -> OracleConfig;
    fn set_oracle_config(ref self: TContractState, asset: ContractAddress, oracle_config: OracleConfig);
    fn set_oracle_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: felt252);
    fn price(self: @TContractState, asset: ContractAddress) -> AssetPrice;

    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(
        ref self: TContractState,
        new_implementation: ClassHash,
        eic_implementation_data: Option<(ClassHash, Span<felt252>)>,
    );
}

#[starknet::contract]
mod Oracle {
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use starknet::storage::StorageMapReadAccess;
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait, get_contract_address};
    use vesu::data_model::AssetPrice;
    use vesu::extension::components::pragma_oracle::pragma_oracle_component::PragmaOracleTrait;
    use vesu::extension::components::pragma_oracle::{OracleConfig, pragma_oracle_component};
    use vesu::oracle::IOracle;
    use vesu::packing::{AssetConfigPacking, PositionPacking};
    use vesu::singleton_v2::{
        IEICDispatcherTrait, IEICLibraryDispatcher, ISingletonV2Dispatcher, ISingletonV2DispatcherTrait,
    };

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        // storage for the pragma oracle component
        #[substorage(v0)]
        pragma_oracle: pragma_oracle_component::Storage,
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
        PragmaOracleEvents: pragma_oracle_component::Event,
        ContractUpgraded: ContractUpgraded,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: pragma_oracle_component, storage: pragma_oracle, event: PragmaOracleEvents);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        oracle_address: ContractAddress,
        summary_address: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.pragma_oracle.set_oracle(oracle_address);
        self.pragma_oracle.set_summary_address(summary_address);
    }

    #[abi(embed_v0)]
    impl OracleV2Impl of IOracle<ContractState> {
        /// Returns the address of the pragma oracle contract
        /// # Returns
        /// * `oracle_address` - address of the pragma oracle contract
        fn pragma_oracle(self: @ContractState) -> ContractAddress {
            self.pragma_oracle.oracle_address()
        }

        /// Returns the address of the pragma summary contract
        /// # Returns
        /// * `summary_address` - address of the pragma summary contract
        fn pragma_summary(self: @ContractState) -> ContractAddress {
            self.pragma_oracle.summary_address()
        }

        /// Returns the oracle configuration for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `oracle_config` - oracle configuration
        fn oracle_config(self: @ContractState, asset: ContractAddress) -> OracleConfig {
            self.pragma_oracle.oracle_configs.read(asset)
        }

        /// Sets oracle config for an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `oracle_config` - oracle configuration
        fn set_oracle_config(ref self: ContractState, asset: ContractAddress, oracle_config: OracleConfig) {
            self.ownable.assert_only_owner();
            self.pragma_oracle.set_oracle_config(asset, oracle_config);
        }

        /// Sets a parameter for a given oracle configuration of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_oracle_parameter(ref self: ContractState, asset: ContractAddress, parameter: felt252, value: felt252) {
            self.ownable.assert_only_owner();
            self.pragma_oracle.set_oracle_parameter(asset, parameter, value);
        }

        /// Returns the price for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `AssetPrice` - latest price of the asset and its validity
        fn price(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            let (value, is_valid) = self.pragma_oracle.price(asset);
            AssetPrice { value, is_valid }
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
            let new_name = ISingletonV2Dispatcher { contract_address: get_contract_address() }.upgrade_name();
            assert(new_name == self.upgrade_name(), 'invalid upgrade name');
            self.emit(ContractUpgraded { new_implementation });
        }
    }
}
