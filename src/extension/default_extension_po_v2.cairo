use starknet::{ClassHash, ContractAddress};
use vesu::extension::components::position_hooks::{
    LiquidationConfig, Pair, ShutdownConfig, ShutdownMode, ShutdownStatus,
};

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct ShutdownParams {
    pub recovery_period: u64, // [seconds]
    pub subscription_period: u64 // [seconds]
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
    fn pool_owner(self: @TContractState) -> ContractAddress;
    fn debt_caps(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> u256;
    fn liquidation_config(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> LiquidationConfig;
    fn shutdown_config(self: @TContractState) -> ShutdownConfig;
    fn shutdown_status(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> ShutdownStatus;
    fn pairs(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> Pair;
    fn create_pool(ref self: TContractState, owner: ContractAddress);
    fn set_debt_cap(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, debt_cap: u256,
    );
    fn set_liquidation_config(
        ref self: TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        liquidation_config: LiquidationConfig,
    );
    fn set_shutdown_config(ref self: TContractState, shutdown_config: ShutdownConfig);
    fn set_shutdown_mode(ref self: TContractState, shutdown_mode: ShutdownMode);
    fn update_shutdown_status(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> ShutdownMode;

    // Upgrade
    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(ref self: TContractState, new_implementation: ClassHash);
}

#[starknet::contract]
mod DefaultExtensionPOV2 {
    use alexandria_math::i257::i257;
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::interface::{IOwnableDispatcher, IOwnableDispatcherTrait};
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::event::EventEmitter;
    use starknet::storage::{StorageMapReadAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::replace_class_syscall;
    #[feature("deprecated-starknet-consts")]
    use starknet::{ClassHash, ContractAddress, get_caller_address, get_contract_address};
    use vesu::data_model::Context;
    use vesu::extension::components::interest_rate_model::interest_rate_model_component::InterestRateModelTrait;
    use vesu::extension::components::position_hooks::position_hooks_component::PositionHooksTrait;
    use vesu::extension::components::position_hooks::{
        LiquidationConfig, Pair, ShutdownConfig, ShutdownMode, ShutdownStatus, position_hooks_component,
    };
    use vesu::extension::default_extension_po_v2::{
        IDefaultExtensionCallback, IDefaultExtensionPOV2, IDefaultExtensionPOV2Dispatcher,
        IDefaultExtensionPOV2DispatcherTrait,
    };
    use vesu::extension::interface::IExtension;
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};

    component!(path: position_hooks_component, storage: position_hooks, event: PositionHooksEvents);

    #[storage]
    struct Storage {
        // address of the singleton contract
        singleton: ContractAddress,
        // tracks the owner
        owner: ContractAddress,
        // storage for the position hooks component
        #[substorage(v0)]
        position_hooks: position_hooks_component::Storage,
    }

    #[derive(Drop, starknet::Event)]
    struct ContractUpgraded {
        new_implementation: ClassHash,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PositionHooksEvents: position_hooks_component::Event,
        ContractUpgraded: ContractUpgraded,
    }

    #[constructor]
    fn constructor(ref self: ContractState, singleton: ContractAddress) {
        self.singleton.write(singleton);
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
    }

    impl DefaultExtensionCallbackImpl of IDefaultExtensionCallback<ContractState> {
        fn singleton(self: @ContractState) -> ContractAddress {
            self.singleton.read()
        }
    }

    #[abi(embed_v0)]
    impl DefaultExtensionPOV2Impl of IDefaultExtensionPOV2<ContractState> {
        /// Returns the owner of a pool
        /// # Returns
        /// * `owner` - address of the owner
        fn pool_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
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
        fn create_pool(ref self: ContractState, owner: ContractAddress) {
            // create the pool in the singleton
            let singleton = ISingletonV2Dispatcher { contract_address: self.singleton.read() };
            singleton.create_pool(extension: get_contract_address());

            // set the pool owner
            self.owner.write(owner);
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

        /// Sets the shutdown config
        /// # Arguments
        /// * `shutdown_config` - shutdown config
        fn set_shutdown_config(ref self: ContractState, shutdown_config: ShutdownConfig) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
            self.position_hooks.set_shutdown_config(shutdown_config);
        }

        /// Sets the shutdown mode and overwrites the inferred shutdown mode
        /// # Arguments
        /// * `shutdown_mode` - shutdown mode
        fn set_shutdown_mode(ref self: ContractState, shutdown_mode: ShutdownMode) {
            let singleton = ISingletonV2Dispatcher { contract_address: self.singleton.read() };
            let shutdown_mode_agent = singleton.shutdown_mode_agent();
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

        /// Modify position callback. Called by the Singleton contract after updating the position.
        /// See `after_modify_position` in `position_hooks.cairo`.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral_delta` - collateral balance delta of the position
        /// * `collateral_shares_delta` - collateral shares balance delta of the position
        /// * `debt_delta` - debt balance delta of the position
        /// * `nominal_debt_delta` - nominal debt balance delta of the position
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
            caller: ContractAddress,
        ) -> bool {
            assert!(get_caller_address() == self.singleton.read(), "caller-not-singleton");
            self
                .position_hooks
                .after_modify_position(
                    context, collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, caller,
                )
        }

        /// Liquidate position callback. Called by the Singleton contract before liquidating the position.
        /// See `before_liquidate_position` in `position_hooks.cairo`.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral` - amount of collateral to be set/added/removed
        /// * `debt` - amount of debt to be set/added/removed
        /// * `min_collateral_to_receive` - minimum amount of collateral to be received
        /// * `debt_to_repay` - amount of debt to be repaid
        /// * `caller` - address of the caller
        /// # Returns
        /// * `collateral` - amount of collateral to be removed
        /// * `debt` - amount of debt to be removed
        /// * `bad_debt` - amount of bad debt accrued during the liquidation
        fn before_liquidate_position(
            ref self: ContractState,
            context: Context,
            min_collateral_to_receive: u256,
            debt_to_repay: u256,
            caller: ContractAddress,
        ) -> (u256, u256, u256) {
            assert!(get_caller_address() == self.singleton.read(), "caller-not-singleton");
            self.position_hooks.before_liquidate_position(context, min_collateral_to_receive, debt_to_repay, caller)
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
                    caller,
                )
        }
    }
}
