use starknet::{ClassHash, ContractAddress};
use vesu::data_model::{AssetParams, LTVConfig, LTVParams};
use vesu::extension::components::interest_rate_model::InterestRateConfig;
use vesu::extension::components::position_hooks::{
    LiquidationConfig, Pair, ShutdownConfig, ShutdownMode, ShutdownStatus,
};
use vesu::extension::components::pragma_oracle::OracleConfig;
use vesu::vendor::pragma::AggregationMode;

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct PragmaOracleParams {
    pub pragma_key: felt252,
    pub timeout: u64, // [seconds]
    pub number_of_sources: u32,
    pub start_time_offset: u64, // [seconds]
    pub time_window: u64, // [seconds]
    pub aggregation_mode: AggregationMode,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct ShutdownParams {
    pub recovery_period: u64, // [seconds]
    pub subscription_period: u64, // [seconds]
    pub ltv_params: Span<LTVParams>,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct LiquidationParams {
    pub collateral_asset_index: usize,
    pub debt_asset_index: usize,
    pub liquidation_factor: u64 // [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct FeeParams {
    pub fee_recipient: ContractAddress,
}

#[starknet::interface]
pub trait IDefaultExtensionCallback<TContractState> {
    fn singleton(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
pub trait IDefaultExtensionPOV2<TContractState> {
    fn pool_name(self: @TContractState) -> felt252;
    fn pool_owner(self: @TContractState) -> ContractAddress;
    fn shutdown_mode_agent(self: @TContractState) -> ContractAddress;
    fn pragma_oracle(self: @TContractState) -> ContractAddress;
    fn pragma_summary(self: @TContractState) -> ContractAddress;
    fn oracle_config(self: @TContractState, asset: ContractAddress) -> OracleConfig;
    fn debt_caps(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> u256;
    fn interest_rate_config(self: @TContractState, asset: ContractAddress) -> InterestRateConfig;
    fn liquidation_config(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> LiquidationConfig;
    fn shutdown_config(self: @TContractState) -> ShutdownConfig;
    fn shutdown_ltv_config(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> LTVConfig;
    fn shutdown_status(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> ShutdownStatus;
    fn pairs(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> Pair;
    fn create_pool(ref self: TContractState, name: felt252, owner: ContractAddress);
    fn add_asset(
        ref self: TContractState,
        asset_params: AssetParams,
        interest_rate_config: InterestRateConfig,
        pragma_oracle_params: PragmaOracleParams,
    );
    fn set_asset_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: u256);
    fn set_debt_cap(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, debt_cap: u256,
    );
    fn set_interest_rate_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: u256);
    fn set_oracle_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: felt252);
    fn set_liquidation_config(
        ref self: TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        liquidation_config: LiquidationConfig,
    );
    fn set_ltv_config(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, ltv_config: LTVConfig,
    );
    fn set_shutdown_config(ref self: TContractState, shutdown_config: ShutdownConfig);
    fn set_shutdown_ltv_config(
        ref self: TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        shutdown_ltv_config: LTVConfig,
    );
    fn set_shutdown_mode(ref self: TContractState, shutdown_mode: ShutdownMode);
    fn set_shutdown_mode_agent(ref self: TContractState, shutdown_mode_agent: ContractAddress);
    fn update_shutdown_status(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> ShutdownMode;

    // Upgrade
    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(ref self: TContractState, new_implementation: ClassHash);
}

#[starknet::contract]
mod DefaultExtensionPOV2 {
    use alexandria_math::i257::{I257Trait, i257};
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::interface::{IOwnableDispatcher, IOwnableDispatcherTrait};
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::event::EventEmitter;
    use starknet::storage::{StorageMapReadAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::replace_class_syscall;
    #[feature("deprecated-starknet-consts")]
    use starknet::{ClassHash, ContractAddress, contract_address_const, get_caller_address, get_contract_address};
    use vesu::data_model::{
        Amount, AmountDenomination, AssetParams, AssetPrice, Context, LTVConfig, ModifyPositionParams,
    };
    use vesu::extension::components::interest_rate_model::interest_rate_model_component::InterestRateModelTrait;
    use vesu::extension::components::interest_rate_model::{InterestRateConfig, interest_rate_model_component};
    use vesu::extension::components::position_hooks::position_hooks_component::PositionHooksTrait;
    use vesu::extension::components::position_hooks::{
        LiquidationConfig, Pair, ShutdownConfig, ShutdownMode, ShutdownStatus, position_hooks_component,
    };
    use vesu::extension::components::pragma_oracle::pragma_oracle_component::PragmaOracleTrait;
    use vesu::extension::components::pragma_oracle::{OracleConfig, pragma_oracle_component};
    use vesu::extension::default_extension_po_v2::{
        IDefaultExtensionCallback, IDefaultExtensionPOV2, IDefaultExtensionPOV2Dispatcher,
        IDefaultExtensionPOV2DispatcherTrait, PragmaOracleParams,
    };
    use vesu::extension::interface::IExtension;
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::units::INFLATION_FEE;

    component!(path: position_hooks_component, storage: position_hooks, event: PositionHooksEvents);
    component!(path: interest_rate_model_component, storage: interest_rate_model, event: InterestRateModelEvents);
    component!(path: pragma_oracle_component, storage: pragma_oracle, event: PragmaOracleEvents);

    #[storage]
    struct Storage {
        // address of the singleton contract
        singleton: ContractAddress,
        // tracks the owner
        owner: ContractAddress,
        // tracks the name
        pool_name: felt252,
        // storage for the position hooks component
        #[substorage(v0)]
        position_hooks: position_hooks_component::Storage,
        // storage for the interest rate model component
        #[substorage(v0)]
        interest_rate_model: interest_rate_model_component::Storage,
        // storage for the pragma oracle component
        #[substorage(v0)]
        pragma_oracle: pragma_oracle_component::Storage,
        // tracks the address that can transition the shutdown mode
        shutdown_mode_agent: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SetShutdownModeAgent {
        #[key]
        agent: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ContractUpgraded {
        new_implementation: ClassHash,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PositionHooksEvents: position_hooks_component::Event,
        InterestRateModelEvents: interest_rate_model_component::Event,
        PragmaOracleEvents: pragma_oracle_component::Event,
        SetShutdownModeAgent: SetShutdownModeAgent,
        ContractUpgraded: ContractUpgraded,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        singleton: ContractAddress,
        oracle_address: ContractAddress,
        summary_address: ContractAddress,
    ) {
        self.singleton.write(singleton);
        self.pragma_oracle.set_oracle(oracle_address);
        self.pragma_oracle.set_summary_address(summary_address);
    }

    /// Helper method for transferring an amount of an asset from one address to another. Reverts if the transfer fails.
    /// # Arguments
    /// * `asset` - address of the asset
    /// * `sender` - address of the sender of the assets
    /// * `to` - address of the receiver of the assets
    /// * `amount` - amount of assets to transfer [asset scale]
    /// * `is_legacy` - whether the asset is a legacy ERC20 (only supporting camelCase instead of snake_case)
    fn transfer_asset(
        asset: ContractAddress, sender: ContractAddress, to: ContractAddress, amount: u256, is_legacy: bool,
    ) {
        let erc20 = IERC20Dispatcher { contract_address: asset };
        if sender == get_contract_address() {
            assert!(erc20.transfer(to, amount), "transfer-failed");
        } else if is_legacy {
            assert!(erc20.transferFrom(sender, to, amount), "transferFrom-failed");
        } else {
            assert!(erc20.transfer_from(sender, to, amount), "transfer-from-failed");
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn assert_singleton_owner(ref self: ContractState) {
            let owner = IOwnableDispatcher { contract_address: self.singleton.read() }.owner();
            assert!(get_caller_address() == owner, "caller-not-singleton-owner");
        }

        fn burn_inflation_fee(ref self: ContractState, asset: ContractAddress, is_legacy: bool) {
            let singleton = ISingletonV2Dispatcher { contract_address: self.singleton.read() };

            // burn inflation fee
            let asset = IERC20Dispatcher { contract_address: asset };
            transfer_asset(
                asset.contract_address, get_caller_address(), get_contract_address(), INFLATION_FEE, is_legacy,
            );
            assert!(asset.approve(singleton.contract_address, INFLATION_FEE), "approve-failed");
            singleton
                .modify_position(
                    ModifyPositionParams {
                        collateral_asset: asset.contract_address,
                        debt_asset: Zero::zero(),
                        user: contract_address_const::<'ZERO'>(),
                        collateral: Amount {
                            denomination: AmountDenomination::Assets, value: I257Trait::new(INFLATION_FEE, false),
                        },
                        debt: Default::default(),
                        data: ArrayTrait::new().span(),
                    },
                );
        }
    }

    impl DefaultExtensionCallbackImpl of IDefaultExtensionCallback<ContractState> {
        fn singleton(self: @ContractState) -> ContractAddress {
            self.singleton.read()
        }
    }

    #[abi(embed_v0)]
    impl DefaultExtensionPOV2Impl of IDefaultExtensionPOV2<ContractState> {
        /// Returns the name of a pool
        /// # Returns
        /// * `name` - name of the pool
        fn pool_name(self: @ContractState) -> felt252 {
            self.pool_name.read()
        }

        /// Returns the owner of a pool
        /// # Returns
        /// * `owner` - address of the owner
        fn pool_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        /// Returns the address of the shutdown mode agent
        /// # Returns
        /// * `shutdown_mode_agent` - address of the shutdown mode agent
        fn shutdown_mode_agent(self: @ContractState) -> ContractAddress {
            self.shutdown_mode_agent.read()
        }

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

        /// Returns the debt cap for a given asset
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `debt_cap` - debt cap
        fn debt_caps(self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> u256 {
            self.position_hooks.debt_caps.read((collateral_asset, debt_asset))
        }

        /// Returns the interest rate configuration for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `interest_rate_config` - interest rate configuration
        fn interest_rate_config(self: @ContractState, asset: ContractAddress) -> InterestRateConfig {
            self.interest_rate_model.interest_rate_configs.read(asset)
        }

        /// Returns the liquidation configuration for a given pairing of assets
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `liquidation_config` - liquidation configuration
        fn liquidation_config(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> LiquidationConfig {
            self.position_hooks.liquidation_configs.read((collateral_asset, debt_asset))
        }

        /// Returns the shutdown configuration
        /// # Returns
        /// * `recovery_period` - recovery period
        /// * `subscription_period` - subscription period
        fn shutdown_config(self: @ContractState) -> ShutdownConfig {
            self.position_hooks.shutdown_config.read()
        }

        /// Returns the shutdown LTV configuration for a given pair
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `shutdown_ltv_config` - shutdown LTV configuration
        fn shutdown_ltv_config(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> LTVConfig {
            self.position_hooks.shutdown_ltv_configs.read((collateral_asset, debt_asset))
        }

        /// Returns the total (sum of all positions) collateral shares and nominal debt balances for a given pair
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `total_collateral_shares` - total collateral shares
        /// * `total_nominal_debt` - total nominal debt
        fn pairs(self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> Pair {
            self.position_hooks.pairs.read((collateral_asset, debt_asset))
        }

        /// Creates a new pool
        /// # Arguments
        /// * `name` - name of the pool
        /// * `asset_params` - asset parameters
        /// * `ltv_params` - loan-to-value parameters
        /// * `interest_rate_params` - interest rate model parameters
        /// * `pragma_oracle_params` - pragma oracle parameters
        /// * `liquidation_params` - liquidation parameters
        /// * `debt_caps` - debt caps
        /// * `shutdown_params` - shutdown parameters
        /// * `fee_params` - fee model parameters
        fn create_pool(ref self: ContractState, name: felt252, owner: ContractAddress) {
            // create the pool in the singleton
            let singleton = ISingletonV2Dispatcher { contract_address: self.singleton.read() };
            singleton.create_pool(extension: get_contract_address());

            // set the pool name
            self.pool_name.write(name);

            // set the pool owner
            self.owner.write(owner);
        }

        /// Adds an asset
        /// # Arguments
        /// * `asset_params` - asset parameters
        /// * `interest_rate_model` - interest rate model
        /// * `pragma_oracle_params` - pragma oracle parameters
        fn add_asset(
            ref self: ContractState,
            asset_params: AssetParams,
            interest_rate_config: InterestRateConfig,
            pragma_oracle_params: PragmaOracleParams,
        ) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            let asset = asset_params.asset;

            // set the oracle config
            self
                .pragma_oracle
                .set_oracle_config(
                    asset,
                    OracleConfig {
                        pragma_key: pragma_oracle_params.pragma_key,
                        timeout: pragma_oracle_params.timeout,
                        number_of_sources: pragma_oracle_params.number_of_sources,
                        start_time_offset: pragma_oracle_params.start_time_offset,
                        time_window: pragma_oracle_params.time_window,
                        aggregation_mode: pragma_oracle_params.aggregation_mode,
                    },
                );

            // set the interest rate model configuration
            self.interest_rate_model.set_interest_rate_config(asset, interest_rate_config);

            let singleton = ISingletonV2Dispatcher { contract_address: self.singleton.read() };
            singleton.set_asset_config(asset_params);

            // burn inflation fee
            self.burn_inflation_fee(asset, asset_params.is_legacy);
        }

        /// Sets the debt cap for a given asset
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `debt_cap` - debt cap
        fn set_debt_cap(
            ref self: ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, debt_cap: u256,
        ) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.position_hooks.set_debt_cap(collateral_asset, debt_asset, debt_cap);
        }

        /// Sets a parameter for a given interest rate configuration for an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_interest_rate_parameter(
            ref self: ContractState, asset: ContractAddress, parameter: felt252, value: u256,
        ) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.interest_rate_model.set_interest_rate_parameter(asset, parameter, value);
        }

        /// Sets a parameter for a given oracle configuration of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_oracle_parameter(ref self: ContractState, asset: ContractAddress, parameter: felt252, value: felt252) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.pragma_oracle.set_oracle_parameter(asset, parameter, value);
        }

        /// Sets the loan-to-value configuration between two assets (pair)
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `ltv_config` - ltv configuration
        fn set_ltv_config(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            ltv_config: LTVConfig,
        ) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            ISingletonV2Dispatcher { contract_address: self.singleton.read() }
                .set_ltv_config(collateral_asset, debt_asset, ltv_config);
        }

        /// Sets the liquidation config for a given pair
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `liquidation_config` - liquidation config
        fn set_liquidation_config(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            liquidation_config: LiquidationConfig,
        ) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.position_hooks.set_liquidation_config(collateral_asset, debt_asset, liquidation_config);
        }

        /// Sets a parameter of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_asset_parameter(ref self: ContractState, asset: ContractAddress, parameter: felt252, value: u256) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            ISingletonV2Dispatcher { contract_address: self.singleton.read() }
                .set_asset_parameter(asset, parameter, value);
        }

        /// Sets the shutdown config
        /// # Arguments
        /// * `shutdown_config` - shutdown config
        fn set_shutdown_config(ref self: ContractState, shutdown_config: ShutdownConfig) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.position_hooks.set_shutdown_config(shutdown_config);
        }

        /// Sets the shutdown LTV config for a given pair
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `shutdown_ltv_config` - shutdown LTV config
        fn set_shutdown_ltv_config(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            shutdown_ltv_config: LTVConfig,
        ) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.position_hooks.set_shutdown_ltv_config(collateral_asset, debt_asset, shutdown_ltv_config);
        }

        /// Sets the shutdown mode agent
        /// # Arguments
        /// * `shutdown_mode_agent` - address of the shutdown mode agent
        fn set_shutdown_mode_agent(ref self: ContractState, shutdown_mode_agent: ContractAddress) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.shutdown_mode_agent.write(shutdown_mode_agent);
            self.emit(SetShutdownModeAgent { agent: shutdown_mode_agent });
        }

        /// Sets the shutdown mode and overwrites the inferred shutdown mode
        /// # Arguments
        /// * `shutdown_mode` - shutdown mode
        fn set_shutdown_mode(ref self: ContractState, shutdown_mode: ShutdownMode) {
            let shutdown_mode_agent = self.shutdown_mode_agent.read();
            assert!(
                get_caller_address() == self.owner.read() || get_caller_address() == shutdown_mode_agent,
                "caller-not-owner-or-agent",
            );
            assert!(
                get_caller_address() != shutdown_mode_agent || shutdown_mode == ShutdownMode::Recovery,
                "shutdown-mode-not-recovery",
            );
            self.position_hooks.set_shutdown_mode(shutdown_mode);
        }

        /// Returns the shutdown mode for a specific pair.
        /// To check the shutdown status of the pool, the shutdown mode for all pairs must be checked.
        /// See `shutdown_status` in `position_hooks.cairo`.
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `shutdown_mode` - shutdown mode
        /// * `violation` - whether the pair currently violates any of the invariants (transitioned to recovery mode)
        /// * `previous_violation_timestamp` - timestamp at which the pair previously violated the invariants
        /// (transitioned to recovery mode)
        /// * `count_at_violation_timestamp_timestamp` - count of how many pairs violated the invariants at that
        /// timestamp
        fn shutdown_status(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> ShutdownStatus {
            let singleton = ISingletonV2Dispatcher { contract_address: self.singleton.read() };
            let mut context = singleton.context(collateral_asset, debt_asset, Zero::zero());
            self.position_hooks.shutdown_status(ref context)
        }

        /// Updates the shutdown mode for a specific pair.
        /// See `update_shutdown_status` in `position_hooks.cairo`.
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `shutdown_mode` - shutdown mode
        fn update_shutdown_status(
            ref self: ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> ShutdownMode {
            let singleton = ISingletonV2Dispatcher { contract_address: self.singleton.read() };
            let mut context = singleton.context(collateral_asset, debt_asset, Zero::zero());
            self.position_hooks.update_shutdown_status(ref context)
        }

        /// Returns the name of the contract
        /// # Returns
        /// * `name` - the name of the contract
        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu default extension po v2'
        }

        /// Upgrades the contract to a new implementation
        /// # Arguments
        /// * `new_implementation` - the new implementation class hash
        fn upgrade(ref self: ContractState, new_implementation: ClassHash) {
            self.assert_singleton_owner();
            replace_class_syscall(new_implementation).unwrap();
            // Check to prevent mistakes when upgrading the contract
            let new_name = IDefaultExtensionPOV2Dispatcher { contract_address: get_contract_address() }.upgrade_name();
            assert!(new_name == self.upgrade_name(), "invalid-upgrade-name");
            self.emit(ContractUpgraded { new_implementation });
        }
    }

    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        /// Returns the address of the singleton contract
        /// # Returns
        /// * `singleton` - address of the singleton contract
        fn singleton(self: @ContractState) -> ContractAddress {
            self.singleton.read()
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

        /// Returns the current interest rate for a given asset, given it's utilization
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `utilization` - utilization of the asset
        /// * `last_updated` - last time the interest rate was updated
        /// * `last_full_utilization_rate` - The interest value when utilization is 100% [SCALE]
        /// # Returns
        /// * `interest_rate` - current interest rate
        fn interest_rate(
            self: @ContractState,
            asset: ContractAddress,
            utilization: u256,
            last_updated: u64,
            last_full_utilization_rate: u256,
        ) -> u256 {
            let (interest_rate, _) = self
                .interest_rate_model
                .interest_rate(asset, utilization, last_updated, last_full_utilization_rate);
            interest_rate
        }

        /// Returns the current rate accumulator for a given asset, given it's utilization
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `utilization` - utilization of the asset
        /// * `last_updated` - last time the interest rate was updated
        /// * `last_rate_accumulator` - last rate accumulator
        /// * `last_full_utilization_rate` - the interest value when utilization is 100% [SCALE]
        /// # Returns
        /// * `rate_accumulator` - current rate accumulator
        /// * `last_full_utilization_rate` - the interest value when utilization is 100% [SCALE]
        fn rate_accumulator(
            self: @ContractState,
            asset: ContractAddress,
            utilization: u256,
            last_updated: u64,
            last_rate_accumulator: u256,
            last_full_utilization_rate: u256,
        ) -> (u256, u256) {
            self
                .interest_rate_model
                .rate_accumulator(asset, utilization, last_updated, last_rate_accumulator, last_full_utilization_rate)
        }

        /// Modify position callback. Called by the Singleton contract after updating the position.
        /// See `after_modify_position` in `position_hooks.cairo`.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral_delta` - collateral balance delta of the position
        /// * `collateral_shares_delta` - collateral shares balance delta of the position
        /// * `debt_delta` - debt balance delta of the position
        /// * `nominal_debt_delta` - nominal debt balance delta of the position
        /// * `data` - modify position data
        /// * `caller` - address of the caller
        /// # Returns
        /// * `bool` - true if the callback was successful
        fn after_modify_position(
            ref self: ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            data: Span<felt252>,
            caller: ContractAddress,
        ) -> bool {
            assert!(get_caller_address() == self.singleton.read(), "caller-not-singleton");
            self
                .position_hooks
                .after_modify_position(
                    context, collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, data, caller,
                )
        }

        /// Liquidate position callback. Called by the Singleton contract before liquidating the position.
        /// See `before_liquidate_position` in `position_hooks.cairo`.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral` - amount of collateral to be set/added/removed
        /// * `debt` - amount of debt to be set/added/removed
        /// * `data` - liquidation data
        /// * `caller` - address of the caller
        /// # Returns
        /// * `collateral` - amount of collateral to be removed
        /// * `debt` - amount of debt to be removed
        /// * `bad_debt` - amount of bad debt accrued during the liquidation
        fn before_liquidate_position(
            ref self: ContractState, context: Context, data: Span<felt252>, caller: ContractAddress,
        ) -> (u256, u256, u256) {
            assert!(get_caller_address() == self.singleton.read(), "caller-not-singleton");
            self.position_hooks.before_liquidate_position(context, data, caller)
        }

        /// Liquidate position callback. Called by the Singleton contract after liquidating the position.
        /// See `before_liquidate_position` in `position_hooks.cairo`.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral_delta` - collateral balance delta of the position
        /// * `collateral_shares_delta` - collateral shares balance delta of the position
        /// * `debt_delta` - debt balance delta of the position
        /// * `nominal_debt_delta` - nominal debt balance delta of the position
        /// * `bad_debt` - accrued bad debt from the liquidation
        /// * `data` - liquidation data
        /// * `caller` - address of the caller
        /// # Returns
        /// * `bool` - true if the callback was successful
        fn after_liquidate_position(
            ref self: ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            bad_debt: u256,
            data: Span<felt252>,
            caller: ContractAddress,
        ) -> bool {
            assert!(get_caller_address() == self.singleton.read(), "caller-not-singleton");
            self
                .position_hooks
                .after_liquidate_position(
                    context,
                    collateral_delta,
                    collateral_shares_delta,
                    debt_delta,
                    nominal_debt_delta,
                    bad_debt,
                    data,
                    caller,
                )
        }
    }
}
