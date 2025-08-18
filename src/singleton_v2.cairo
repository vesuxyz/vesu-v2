use alexandria_math::i257::i257;
use starknet::{ClassHash, ContractAddress};
use vesu::data_model::{
    Amount, AssetConfig, AssetParams, AssetPrice, Context, FeeConfig, LTVConfig, LiquidatePositionParams,
    ModifyPositionParams, Position, PragmaOracleParams, UpdatePositionResponse,
};
use vesu::extension::components::interest_rate_model::InterestRateConfig;
use vesu::extension::components::pragma_oracle::OracleConfig;

#[starknet::interface]
pub trait IFlashLoanReceiver<TContractState> {
    fn on_flash_loan(
        ref self: TContractState, sender: ContractAddress, asset: ContractAddress, amount: u256, data: Span<felt252>,
    );
}

#[starknet::interface]
pub trait ISingletonV2<TContractState> {
    fn pool_name(self: @TContractState) -> felt252;
    fn extension(self: @TContractState) -> ContractAddress;
    fn asset_config(self: @TContractState, asset: ContractAddress) -> AssetConfig;
    fn ltv_config(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> LTVConfig;
    fn position(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> (Position, u256, u256);
    fn check_collateralization(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> (bool, u256, u256);
    fn rate_accumulator(self: @TContractState, asset: ContractAddress) -> u256;
    fn utilization(self: @TContractState, asset: ContractAddress) -> u256;
    fn delegation(self: @TContractState, delegator: ContractAddress, delegatee: ContractAddress) -> bool;
    fn calculate_debt(self: @TContractState, nominal_debt: i257, rate_accumulator: u256, asset_scale: u256) -> u256;
    fn calculate_nominal_debt(self: @TContractState, debt: i257, rate_accumulator: u256, asset_scale: u256) -> u256;
    fn calculate_collateral_shares(self: @TContractState, asset: ContractAddress, collateral: i257) -> u256;
    fn calculate_collateral(self: @TContractState, asset: ContractAddress, collateral_shares: i257) -> u256;
    fn deconstruct_collateral_amount(
        self: @TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        collateral: Amount,
    ) -> (i257, i257);
    fn deconstruct_debt_amount(
        self: @TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        debt: Amount,
    ) -> (i257, i257);
    fn context(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> Context;
    fn create_pool(ref self: TContractState, extension: ContractAddress);
    fn modify_position(ref self: TContractState, params: ModifyPositionParams) -> UpdatePositionResponse;
    fn liquidate_position(ref self: TContractState, params: LiquidatePositionParams) -> UpdatePositionResponse;
    fn flash_loan(
        ref self: TContractState,
        receiver: ContractAddress,
        asset: ContractAddress,
        amount: u256,
        is_legacy: bool,
        data: Span<felt252>,
    );
    fn modify_delegation(ref self: TContractState, delegatee: ContractAddress, delegation: bool);
    fn donate_to_reserve(ref self: TContractState, asset: ContractAddress, amount: u256);
    fn add_asset(
        ref self: TContractState,
        params: AssetParams,
        interest_rate_config: InterestRateConfig,
        pragma_oracle_params: PragmaOracleParams,
    );
    fn set_ltv_config(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, ltv_config: LTVConfig,
    );
    fn set_asset_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: u256);
    fn update_fee_shares(ref self: TContractState, asset: ContractAddress);
    fn claim_fees(ref self: TContractState, asset: ContractAddress);
    fn get_fees(self: @TContractState, asset: ContractAddress) -> (u256, u256);
    fn fee_config(self: @TContractState) -> FeeConfig;
    fn set_fee_config(ref self: TContractState, fee_config: FeeConfig);
    fn pragma_oracle(self: @TContractState) -> ContractAddress;
    fn pragma_summary(self: @TContractState) -> ContractAddress;
    fn oracle_config(self: @TContractState, asset: ContractAddress) -> OracleConfig;
    fn set_oracle_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: felt252);
    fn price(self: @TContractState, asset: ContractAddress) -> AssetPrice;
    fn interest_rate(
        self: @TContractState,
        asset: ContractAddress,
        utilization: u256,
        last_updated: u64,
        last_full_utilization_rate: u256,
    ) -> u256;
    fn interest_rate_config(self: @TContractState, asset: ContractAddress) -> InterestRateConfig;
    fn set_interest_rate_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: u256);
    fn shutdown_mode_agent(self: @TContractState) -> ContractAddress;
    fn set_shutdown_mode_agent(ref self: TContractState, shutdown_mode_agent: ContractAddress);

    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(ref self: TContractState, new_implementation: ClassHash);
}

#[starknet::contract]
mod SingletonV2 {
    use alexandria_math::i257::{I257Trait, i257};
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::security::pausable::PausableComponent;
    use openzeppelin::security::pausable::PausableComponent::InternalImpl as PausableComponentImpl;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ClassHash, ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use starkware_utils::components::pausable::interface::IPausable;
    use vesu::common::{
        apply_position_update_to_context, calculate_collateral, calculate_collateral_and_debt_value,
        calculate_collateral_shares, calculate_debt, calculate_fee_shares, calculate_nominal_debt,
        calculate_utilization, deconstruct_collateral_amount, deconstruct_debt_amount, is_collateralized,
    };
    use vesu::data_model::{
        Amount, AmountDenomination, AssetConfig, AssetParams, AssetPrice, Context, FeeConfig, LTVConfig,
        LiquidatePositionParams, ModifyPositionParams, Position, PragmaOracleParams, UpdatePositionResponse,
        assert_asset_config, assert_asset_config_exists, assert_ltv_config,
    };
    use vesu::extension::components::interest_rate_model::interest_rate_model_component::InterestRateModelTrait;
    use vesu::extension::components::interest_rate_model::{InterestRateConfig, interest_rate_model_component};
    use vesu::extension::components::pragma_oracle::pragma_oracle_component::PragmaOracleTrait;
    use vesu::extension::components::pragma_oracle::{OracleConfig, pragma_oracle_component};
    use vesu::extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use vesu::math::pow_10;
    use vesu::packing::{AssetConfigPacking, PositionPacking, assert_storable_asset_config};
    use vesu::singleton_v2::{
        IFlashLoanReceiverDispatcher, IFlashLoanReceiverDispatcherTrait, ISingletonV2, ISingletonV2Dispatcher,
        ISingletonV2DispatcherTrait,
    };
    use vesu::units::{INFLATION_FEE, SCALE};

    #[storage]
    struct Storage {
        // tracks the name
        pool_name: felt252,
        // The address of the extension contract
        extension: ContractAddress,
        // The owner of the extension
        extension_owner: ContractAddress,
        // The address of the pauser
        pauser: ContractAddress,
        // tracks the configuration / state of each asset
        // asset -> asset configuration
        asset_configs: Map<ContractAddress, AssetConfig>,
        // tracks the max. allowed loan-to-value ratio for each asset pairing
        // (collateral_asset, debt_asset) -> ltv configuration
        ltv_configs: Map<(ContractAddress, ContractAddress), LTVConfig>,
        // tracks the state of each position
        // (collateral_asset, debt_asset, user) -> position
        positions: Map<(ContractAddress, ContractAddress, ContractAddress), Position>,
        // tracks the delegation status for each delegator to a delegatee
        // (delegator, delegatee) -> delegation
        delegations: Map<(ContractAddress, ContractAddress), bool>,
        // fee configuration
        fee_config: FeeConfig,
        // tracks the address that can transition the shutdown mode
        shutdown_mode_agent: ContractAddress,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        // storage for the pragma oracle component
        #[substorage(v0)]
        pragma_oracle: pragma_oracle_component::Storage,
        // storage for the interest rate model component
        #[substorage(v0)]
        interest_rate_model: interest_rate_model_component::Storage,
    }

    #[derive(Drop, starknet::Event)]
    struct ModifyPosition {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        #[key]
        user: ContractAddress,
        collateral_delta: i257,
        collateral_shares_delta: i257,
        debt_delta: i257,
        nominal_debt_delta: i257,
    }

    #[derive(Drop, starknet::Event)]
    struct LiquidatePosition {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        #[key]
        user: ContractAddress,
        #[key]
        liquidator: ContractAddress,
        collateral_delta: i257,
        collateral_shares_delta: i257,
        debt_delta: i257,
        nominal_debt_delta: i257,
        bad_debt: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct UpdateContext {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        collateral_asset_config: AssetConfig,
        debt_asset_config: AssetConfig,
        collateral_asset_price: AssetPrice,
        debt_asset_price: AssetPrice,
    }

    #[derive(Drop, starknet::Event)]
    struct Flashloan {
        #[key]
        sender: ContractAddress,
        #[key]
        receiver: ContractAddress,
        #[key]
        asset: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ModifyDelegation {
        #[key]
        delegator: ContractAddress,
        #[key]
        delegatee: ContractAddress,
        delegation: bool,
    }

    #[derive(Drop, starknet::Event)]
    struct Donate {
        #[key]
        asset: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct SetLTVConfig {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        ltv_config: LTVConfig,
    }

    #[derive(Drop, starknet::Event)]
    struct SetAssetConfig {
        #[key]
        asset: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SetAssetParameter {
        #[key]
        asset: ContractAddress,
        #[key]
        parameter: felt252,
        value: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct SetExtension {
        #[key]
        extension: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ContractUpgraded {
        new_implementation: ClassHash,
    }

    #[derive(Drop, starknet::Event)]
    struct ClaimFees {
        #[key]
        asset: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetFeeConfig {
        #[key]
        fee_config: FeeConfig,
    }

    #[derive(Drop, starknet::Event)]
    struct SetShutdownModeAgent {
        #[key]
        agent: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        PragmaOracleEvents: pragma_oracle_component::Event,
        InterestRateModelEvents: interest_rate_model_component::Event,
        ModifyPosition: ModifyPosition,
        LiquidatePosition: LiquidatePosition,
        UpdateContext: UpdateContext,
        Flashloan: Flashloan,
        ModifyDelegation: ModifyDelegation,
        Donate: Donate,
        SetLTVConfig: SetLTVConfig,
        SetAssetConfig: SetAssetConfig,
        SetAssetParameter: SetAssetParameter,
        SetExtension: SetExtension,
        ContractUpgraded: ContractUpgraded,
        ClaimFees: ClaimFees,
        SetFeeConfig: SetFeeConfig,
        SetShutdownModeAgent: SetShutdownModeAgent,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: pragma_oracle_component, storage: pragma_oracle, event: PragmaOracleEvents);
    component!(path: interest_rate_model_component, storage: interest_rate_model, event: InterestRateModelEvents);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;
    impl PausableImplOZ = PausableComponent::PausableImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        owner: ContractAddress,
        pauser: ContractAddress,
        oracle_address: ContractAddress,
        summary_address: ContractAddress,
    ) {
        self.pool_name.write(name);
        self.ownable.initializer(owner);
        assert!(pauser.is_non_zero(), "invalid-zero-address");
        self.pauser.write(pauser);

        // TODO: Support a different owner for the extension.
        self.extension_owner.write(owner);
        self.pragma_oracle.set_oracle(oracle_address);
        self.pragma_oracle.set_summary_address(summary_address);
    }

    /// Computes the current utilization of an asset in a pool
    /// # Arguments
    /// * `asset_config` - asset configuration
    /// # Returns
    /// * `utilization` - current utilization [SCALE]
    fn utilization(asset_config: AssetConfig) -> u256 {
        let total_debt = calculate_debt(
            asset_config.total_nominal_debt, asset_config.last_rate_accumulator, asset_config.scale, false,
        );
        calculate_utilization(asset_config.reserve, total_debt)
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
        /// Asserts that the delegatee has the delegate of the delegator
        fn assert_ownership(ref self: ContractState, extension: ContractAddress, delegator: ContractAddress) {
            let has_delegation = self.delegations.read((delegator, get_caller_address()));
            assert!(
                delegator == get_caller_address() || extension == get_caller_address() || has_delegation,
                "no-delegation",
            );
        }

        /// Asserts that the current utilization of an asset is below the max. allowed utilization
        fn assert_max_utilization(ref self: ContractState, asset_config: AssetConfig) {
            assert!(utilization(asset_config) <= asset_config.max_utilization, "utilization-exceeded")
        }

        /// Asserts that the collateralization of a position is not above the max. loan-to-value ratio
        fn assert_collateralization(
            ref self: ContractState, collateral_value: u256, debt_value: u256, max_ltv_ratio: u256,
        ) {
            assert!(is_collateralized(collateral_value, debt_value, max_ltv_ratio), "not-collateralized");
        }

        /// Asserts invariants a position has to fulfill at all times (excluding liquidations)
        fn assert_position_invariants(
            ref self: ContractState, context: Context, collateral_delta: i257, debt_delta: i257,
        ) {
            if collateral_delta < Zero::zero() || debt_delta > Zero::zero() {
                // position is collateralized
                let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(
                    context, context.position,
                );
                self.assert_collateralization(collateral_value, debt_value, context.max_ltv.into());
                // caller owns the position or has a delegate for modifying it
                self.assert_ownership(context.extension, context.user);
                if collateral_delta < Zero::zero() {
                    // max. utilization of the collateral is not exceed
                    self.assert_max_utilization(context.collateral_asset_config);
                }
                if debt_delta > Zero::zero() {
                    // max. utilization of the collateral is not exceed
                    self.assert_max_utilization(context.debt_asset_config);
                }
            }
        }

        /// Asserts that the deltas are either both zero or non-zero for collateral and debt
        /// Note: Shutdown mode constraints on collateral and debt deltas are dependent on these invariants
        fn assert_delta_invariants(
            ref self: ContractState,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
        ) {
            // collateral shares delta has to be zero if the collateral delta is zero
            assert!((collateral_delta.abs() == 0) == (collateral_shares_delta.abs() == 0), "zero-collateral");
            // nominal debt delta has to be zero if the debt delta is zero
            assert!((debt_delta.abs() == 0) == (nominal_debt_delta.abs() == 0), "zero-debt");
        }

        /// Asserts that the position's balances aren't below the floor (dusty)
        fn assert_floor_invariant(ref self: ContractState, context: Context) {
            let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(context, context.position);

            if context.position.nominal_debt != 0 {
                // value of the collateral is either zero or above the floor
                assert!(
                    collateral_value == 0 || collateral_value > context.collateral_asset_config.floor,
                    "dusty-collateral-balance",
                );
            }

            // value of the outstanding debt is either zero or above the floor
            assert!(debt_value == 0 || debt_value > context.debt_asset_config.floor, "dusty-debt-balance");
        }

        /// Sets the pool's extension address.
        fn _set_extension(ref self: ContractState, extension: ContractAddress) {
            assert!(extension.is_non_zero(), "extension-is-zero");
            self.extension.write(extension);
            self.emit(SetExtension { extension });
        }

        /// Settles all intermediate outstanding collateral and debt deltas for a position / user
        fn settle_position(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            collateral_delta: i257,
            debt_asset: ContractAddress,
            debt_delta: i257,
            bad_debt: u256,
        ) {
            let (contract, caller) = (get_contract_address(), get_caller_address());

            if collateral_delta < Zero::zero() {
                let asset_config = self.asset_config(collateral_asset);
                transfer_asset(collateral_asset, contract, caller, collateral_delta.abs(), asset_config.is_legacy);
            } else if collateral_delta > Zero::zero() {
                let asset_config = self.asset_config(collateral_asset);
                transfer_asset(collateral_asset, caller, contract, collateral_delta.abs(), asset_config.is_legacy);
            }

            if debt_delta < Zero::zero() {
                let asset_config = self.asset_config(debt_asset);
                transfer_asset(debt_asset, caller, contract, debt_delta.abs() - bad_debt, asset_config.is_legacy);
            } else if debt_delta > Zero::zero() {
                let asset_config = self.asset_config(debt_asset);
                transfer_asset(debt_asset, contract, caller, debt_delta.abs(), asset_config.is_legacy);
            }
        }

        /// Updates the state of a position and the corresponding collateral and debt asset
        fn update_position(
            ref self: ContractState, ref context: Context, collateral: Amount, debt: Amount, bad_debt: u256,
        ) -> UpdatePositionResponse {
            // apply the position modification to the context
            let (collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta) =
                apply_position_update_to_context(
                ref context, collateral, debt, bad_debt,
            );

            let Context { collateral_asset, debt_asset, user, .. } = context;

            // store updated context
            self.positions.write((collateral_asset, debt_asset, user), context.position);
            self.asset_configs.write((collateral_asset), context.collateral_asset_config);
            self.asset_configs.write((debt_asset), context.debt_asset_config);

            self
                .emit(
                    UpdateContext {
                        collateral_asset,
                        debt_asset,
                        collateral_asset_config: context.collateral_asset_config,
                        debt_asset_config: context.debt_asset_config,
                        collateral_asset_price: context.collateral_asset_price,
                        debt_asset_price: context.debt_asset_price,
                    },
                );

            // verify invariants:
            self.assert_delta_invariants(collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta);
            self.assert_floor_invariant(context);

            UpdatePositionResponse {
                collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, bad_debt,
            }
        }

        /// Computes the new rate accumulator and the interest rate at full utilization for a given asset
        /// # Arguments
        /// * `extension` - address of the extension contract
        /// * `asset` - address of the asset
        /// # Returns
        /// * `asset_config` - asset config containing the updated last rate accumulator and full utilization rate
        fn new_rate_accumulator(
            self: @ContractState, asset: ContractAddress, mut asset_config: AssetConfig,
        ) -> AssetConfig {
            let AssetConfig { total_nominal_debt, scale, .. } = asset_config;
            let AssetConfig { last_rate_accumulator, last_full_utilization_rate, last_updated, .. } = asset_config;
            let total_debt = calculate_debt(total_nominal_debt, last_rate_accumulator, scale, false);
            // calculate utilization based on previous rate accumulator
            let utilization = calculate_utilization(asset_config.reserve, total_debt);
            // calculate the new rate accumulator
            let (rate_accumulator, full_utilization_rate) = self
                .interest_rate_model
                .rate_accumulator(asset, utilization, last_updated, last_rate_accumulator, last_full_utilization_rate);

            asset_config.last_rate_accumulator = rate_accumulator;
            asset_config.last_full_utilization_rate = full_utilization_rate;
            asset_config.last_updated = get_block_timestamp();

            asset_config
        }
    }

    #[abi(embed_v0)]
    impl SingletonV2Impl of ISingletonV2<ContractState> {
        /// Returns the name of a pool
        /// # Returns
        /// * `name` - name of the pool
        fn pool_name(self: @ContractState) -> felt252 {
            self.pool_name.read()
        }

        /// Returns the extension address
        /// # Returns
        /// * `extension` - address of the extension contract
        fn extension(self: @ContractState) -> ContractAddress {
            self.extension.read()
        }

        /// Returns the configuration / state of an asset
        /// This method does not prevent reentrancy which may result in asset_config being out of date.
        /// For contract to contract interactions asset_config() should be used instead.
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `asset_config` - asset configuration
        fn asset_config(self: @ContractState, asset: ContractAddress) -> AssetConfig {
            let extension = self.extension.read();
            assert!(extension.is_non_zero(), "unknown-pool");

            let mut asset_config = self.asset_configs.read(asset);
            if asset.is_non_zero() {
                // Check that the asset is registered.
                assert_asset_config_exists(asset_config);
            }

            if asset_config.last_updated != get_block_timestamp() && asset != Zero::zero() {
                let new_asset_config = self.new_rate_accumulator(asset, asset_config);
                let fee_shares = calculate_fee_shares(asset_config, new_asset_config.last_rate_accumulator);
                asset_config = new_asset_config;
                asset_config.total_collateral_shares += fee_shares;
                asset_config.fee_shares += fee_shares;
            }

            asset_config
        }

        /// Returns the loan-to-value configuration between two assets (pair)
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `ltv_config` - ltv configuration
        fn ltv_config(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> LTVConfig {
            self.ltv_configs.read((collateral_asset, debt_asset))
        }

        /// Returns the current state of a position
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// # Returns
        /// * `position` - position state
        /// * `collateral` - amount of collateral (computed from position.collateral_shares) [asset scale]
        /// * `debt` - amount of debt (computed from position.nominal_debt) [asset scale]
        fn position(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
        ) -> (Position, u256, u256) {
            let context = self.context(collateral_asset, debt_asset, user);
            let (collateral, _, debt, _) = calculate_collateral_and_debt_value(context, context.position);
            (context.position, collateral, debt)
        }

        /// Checks if a position is collateralized according to the max. loan-to-value ratio
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// # Returns
        /// * `collateralized` - true if the position is collateralized, false otherwise
        /// * `collateral_value` - USD value of the collateral [SCALE]
        /// * `debt_value` - USD value of the debt [SCALE]
        fn check_collateralization(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
        ) -> (bool, u256, u256) {
            let context = self.context(collateral_asset, debt_asset, user);
            let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(context, context.position);
            (is_collateralized(collateral_value, debt_value, context.max_ltv.into()), collateral_value, debt_value)
        }

        /// Calculates the current (using the current block's timestamp) rate accumulator for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `rate_accumulator` - computed rate accumulator [SCALE]
        fn rate_accumulator(self: @ContractState, asset: ContractAddress) -> u256 {
            let asset_config = self.asset_config(asset);
            asset_config.last_rate_accumulator
        }

        /// Calculates the current utilization of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `utilization` - computed utilization [SCALE]
        fn utilization(self: @ContractState, asset: ContractAddress) -> u256 {
            let asset_config = self.asset_config(asset);
            utilization(asset_config)
        }

        /// Returns the delegation status of a delegator to a delegatee
        /// # Arguments
        /// * `delegator` - address of the delegator
        /// * `delegatee` - address of the delegatee
        /// # Returns
        /// * `delegation` - delegation status (true = delegate, false = undelegate)
        fn delegation(self: @ContractState, delegator: ContractAddress, delegatee: ContractAddress) -> bool {
            self.delegations.read((delegator, delegatee))
        }

        /// Calculates the debt for a given amount of nominal debt, the current rate accumulator and debt asset's scale
        /// # Arguments
        /// * `nominal_debt` - amount of nominal debt [asset scale]
        /// * `rate_accumulator` - current rate accumulator [SCALE]
        /// * `asset_scale` - debt asset's scale
        /// # Returns
        /// * `debt` - computed debt [asset scale]
        fn calculate_debt(self: @ContractState, nominal_debt: i257, rate_accumulator: u256, asset_scale: u256) -> u256 {
            calculate_debt(nominal_debt.abs(), rate_accumulator, asset_scale, nominal_debt.is_negative())
        }

        /// Calculates the nominal debt for a given amount of debt, the current rate accumulator and debt asset's scale
        /// # Arguments
        /// * `debt` - amount of debt [asset scale]
        /// * `rate_accumulator` - current rate accumulator [SCALE]
        /// * `asset_scale` - debt asset's scale
        /// # Returns
        /// * `nominal_debt` - computed nominal debt [asset scale]
        fn calculate_nominal_debt(self: @ContractState, debt: i257, rate_accumulator: u256, asset_scale: u256) -> u256 {
            calculate_nominal_debt(debt.abs(), rate_accumulator, asset_scale, !debt.is_negative())
        }

        /// Calculates the number of collateral shares (that would be e.g. minted) for a given amount of collateral
        /// assets # Arguments
        /// * `asset` - address of the asset
        /// * `collateral` - amount of collateral [asset scale]
        /// # Returns
        /// * `collateral_shares` - computed collateral shares [SCALE]
        fn calculate_collateral_shares(self: @ContractState, asset: ContractAddress, collateral: i257) -> u256 {
            let asset_config = self.asset_config(asset);
            calculate_collateral_shares(collateral.abs(), asset_config, collateral.is_negative())
        }

        /// Calculates the amount of collateral assets (that can e.g. be redeemed)  for a given amount of collateral
        /// shares # Arguments
        /// * `asset` - address of the asset
        /// * `collateral_shares` - amount of collateral shares
        /// # Returns
        /// * `collateral` - computed collateral [asset scale]
        fn calculate_collateral(self: @ContractState, asset: ContractAddress, collateral_shares: i257) -> u256 {
            let asset_config = self.asset_config(asset);
            calculate_collateral(collateral_shares.abs(), asset_config, !collateral_shares.is_negative())
        }

        /// Deconstructs the collateral amount into collateral delta, collateral shares delta and it's sign
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// * `collateral` - amount of collateral
        /// # Returns
        /// * `collateral_delta` - computed collateral delta [asset scale]
        /// * `collateral_shares_delta` - computed collateral shares delta [SCALE]
        fn deconstruct_collateral_amount(
            self: @ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
            collateral: Amount,
        ) -> (i257, i257) {
            let context = self.context(collateral_asset, debt_asset, user);
            deconstruct_collateral_amount(collateral, context.collateral_asset_config)
        }

        /// Deconstructs the debt amount into debt delta, nominal debt delta and it's sign
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// * `debt` - amount of debt
        /// # Returns
        /// * `debt_delta` - computed debt delta [asset scale]
        /// * `nominal_debt_delta` - computed nominal debt delta [SCALE]
        fn deconstruct_debt_amount(
            self: @ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
            debt: Amount,
        ) -> (i257, i257) {
            let context = self.context(collateral_asset, debt_asset, user);
            deconstruct_debt_amount(
                debt, context.debt_asset_config.last_rate_accumulator, context.debt_asset_config.scale,
            )
        }

        /// Loads the contextual state for a given user. This includes the extension address, the state of the
        /// collateral and debt assets, loan-to-value configurations and the state of the position.
        /// This method does not prevent reentrancy which may result in context being out of date.
        /// For contract to contract interactions context() should be used instead.
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// # Returns
        /// * `context` - contextual state
        fn context(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
        ) -> Context {
            assert!(collateral_asset != debt_asset, "identical-assets");

            let extension = IExtensionDispatcher { contract_address: self.extension.read() };
            assert!(extension.contract_address.is_non_zero(), "unknown-pool");

            let collateral_asset_config = self.asset_config(collateral_asset);
            let debt_asset_config = self.asset_config(debt_asset);

            Context {
                extension: extension.contract_address,
                collateral_asset,
                debt_asset,
                collateral_asset_config,
                debt_asset_config,
                collateral_asset_price: if collateral_asset == Zero::zero() {
                    AssetPrice { value: 0, is_valid: true }
                } else {
                    self.price(collateral_asset)
                },
                debt_asset_price: if debt_asset == Zero::zero() {
                    AssetPrice { value: 0, is_valid: true }
                } else {
                    self.price(debt_asset)
                },
                max_ltv: self.ltv_configs.read((collateral_asset, debt_asset)).max_ltv,
                user,
                position: self.positions.read((collateral_asset, debt_asset, user)),
            }
        }

        /// Creates a new pool
        /// # Arguments
        /// * `asset_params` - array of asset parameters
        /// * `ltv_params` - array of loan-to-value parameters
        /// * `extension` - address of the extension contract
        // TODO: Move this to the constructor (o.w the functions is not sound).
        fn create_pool(ref self: ContractState, extension: ContractAddress) {
            // link the extension to the pool
            self._set_extension(extension);
        }

        /// Adjusts a positions collateral and debt balances
        /// # Arguments
        /// * `params` - see ModifyPositionParams
        /// # Returns
        /// * `response` - see UpdatePositionResponse
        fn modify_position(ref self: ContractState, params: ModifyPositionParams) -> UpdatePositionResponse {
            self.pausable.assert_not_paused();

            let ModifyPositionParams { collateral_asset, debt_asset, user, collateral, debt } = params;
            let mut context = self.context(collateral_asset, debt_asset, user);

            // update the position
            let response = self.update_position(ref context, collateral, debt, 0);
            let UpdatePositionResponse {
                collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, ..,
            } = response;

            // verify invariants
            self.assert_position_invariants(context, collateral_delta, debt_delta);

            // call after-hook of the extension (assets are not settled yet, only the internal state has been updated)
            let extension = IExtensionDispatcher { contract_address: context.extension };
            assert!(
                extension
                    .after_modify_position(
                        context,
                        collateral_delta,
                        collateral_shares_delta,
                        debt_delta,
                        nominal_debt_delta,
                        get_caller_address(),
                    ),
                "after-modify-position-failed",
            );

            self
                .emit(
                    ModifyPosition {
                        collateral_asset,
                        debt_asset,
                        user,
                        collateral_delta,
                        collateral_shares_delta,
                        debt_delta,
                        nominal_debt_delta,
                    },
                );

            // settle collateral and debt balances
            self.settle_position(params.collateral_asset, collateral_delta, params.debt_asset, debt_delta, 0);

            response
        }

        /// Liquidates a position
        /// # Arguments
        /// * `params` - see LiquidatePositionParams
        /// # Returns
        /// * `response` - see UpdatePositionResponse
        fn liquidate_position(ref self: ContractState, params: LiquidatePositionParams) -> UpdatePositionResponse {
            self.pausable.assert_not_paused();

            let LiquidatePositionParams {
                collateral_asset, debt_asset, user, min_collateral_to_receive, debt_to_repay, ..,
            } = params;

            let context = self.context(collateral_asset, debt_asset, user);

            // call before-hook of the extension
            let extension = IExtensionDispatcher { contract_address: context.extension };
            let (collateral, debt, bad_debt) = extension
                .before_liquidate_position(context, min_collateral_to_receive, debt_to_repay, get_caller_address());

            // convert unsigned amounts to signed amounts
            let collateral = Amount {
                denomination: AmountDenomination::Assets, value: I257Trait::new(collateral, true),
            };
            let debt = Amount { denomination: AmountDenomination::Assets, value: I257Trait::new(debt, true) };

            // reload context since it might have changed by a reentered call
            let mut context = self.context(collateral_asset, debt_asset, user);

            // only allow for liquidation of undercollateralized positions
            let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(context, context.position);
            assert!(
                !is_collateralized(collateral_value, debt_value, context.max_ltv.into()), "not-undercollateralized",
            );

            // update the position
            let response = self.update_position(ref context, collateral, debt, bad_debt);
            let UpdatePositionResponse {
                mut collateral_delta, mut collateral_shares_delta, debt_delta, nominal_debt_delta, bad_debt,
            } = response;

            // call after-hook of the extension (assets are not settled yet, only the internal state has been updated)
            assert!(
                extension
                    .after_liquidate_position(
                        context,
                        collateral_delta,
                        collateral_shares_delta,
                        debt_delta,
                        nominal_debt_delta,
                        bad_debt,
                        get_caller_address(),
                    ),
                "after-liquidate-position-failed",
            );

            self
                .emit(
                    LiquidatePosition {
                        collateral_asset,
                        debt_asset,
                        user,
                        liquidator: get_caller_address(),
                        collateral_delta,
                        collateral_shares_delta,
                        debt_delta,
                        nominal_debt_delta,
                        bad_debt,
                    },
                );

            // settle collateral and debt balances
            self.settle_position(collateral_asset, collateral_delta, debt_asset, debt_delta, bad_debt);

            response
        }

        /// Executes a flash loan
        /// # Arguments
        /// * `receiver` - address of the flash loan receiver
        /// * `asset` - address of the asset
        /// * `amount` - amount of the asset to loan
        /// * `data` - data to pass to the flash loan receiver
        fn flash_loan(
            ref self: ContractState,
            receiver: ContractAddress,
            asset: ContractAddress,
            amount: u256,
            is_legacy: bool,
            data: Span<felt252>,
        ) {
            self.pausable.assert_not_paused();

            transfer_asset(asset, get_contract_address(), receiver, amount, is_legacy);
            IFlashLoanReceiverDispatcher { contract_address: receiver }
                .on_flash_loan(get_caller_address(), asset, amount, data);
            transfer_asset(asset, receiver, get_contract_address(), amount, is_legacy);

            self.emit(Flashloan { sender: get_caller_address(), receiver, asset, amount });
        }

        /// Modifies the delegation status of a delegator to a delegatee
        /// # Arguments
        /// * `delegatee` - address of the delegatee
        /// * `delegation` - delegation status (true = delegate, false = undelegate)
        fn modify_delegation(ref self: ContractState, delegatee: ContractAddress, delegation: bool) {
            self.delegations.write((get_caller_address(), delegatee), delegation);

            self.emit(ModifyDelegation { delegator: get_caller_address(), delegatee, delegation });
        }

        /// Donates an amount of an asset to the pool's reserve
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `amount` - amount to donate [asset scale]
        fn donate_to_reserve(ref self: ContractState, asset: ContractAddress, amount: u256) {
            assert!(get_caller_address() == self.extension_owner.read(), "caller-not-extension-owner");
            let mut asset_config = self.asset_config(asset);
            assert_asset_config_exists(asset_config);
            // donate amount to the reserve
            asset_config.reserve += amount;
            self.asset_configs.write(asset, asset_config);
            transfer_asset(asset, get_caller_address(), get_contract_address(), amount, asset_config.is_legacy);

            self.emit(Donate { asset, amount });
        }

        /// Sets the loan-to-value configuration between two assets (pair) in the pool
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
            assert!(get_caller_address() == self.extension_owner.read(), "caller-not-extension-owner");
            assert!(collateral_asset != debt_asset, "identical-assets");
            assert_ltv_config(ltv_config);

            self.ltv_configs.write((collateral_asset, debt_asset), ltv_config);

            self.emit(SetLTVConfig { collateral_asset, debt_asset, ltv_config });
        }

        /// Adds a new asset to the pool
        /// # Arguments
        /// * `params` - see AssetParams
        fn add_asset(
            ref self: ContractState,
            params: AssetParams,
            interest_rate_config: InterestRateConfig,
            pragma_oracle_params: PragmaOracleParams,
        ) {
            let caller = get_caller_address();
            assert!(caller == self.extension_owner.read(), "caller-not-extension-owner");
            assert!(self.asset_configs.read((params.asset)).scale == 0, "asset-config-already-exists");

            let asset = IERC20Dispatcher { contract_address: params.asset };
            let scale = pow_10(asset.decimals().into());
            let total_collateral_shares = u256_mul_div(INFLATION_FEE, SCALE, scale, Rounding::Floor);

            let asset_config = AssetConfig {
                total_collateral_shares,
                total_nominal_debt: 0,
                reserve: INFLATION_FEE,
                max_utilization: params.max_utilization,
                floor: params.floor,
                scale,
                is_legacy: params.is_legacy,
                last_updated: get_block_timestamp(),
                last_rate_accumulator: params.initial_rate_accumulator,
                last_full_utilization_rate: params.initial_full_utilization_rate,
                fee_rate: params.fee_rate,
                fee_shares: 0,
            };

            assert_asset_config(asset_config);
            assert_storable_asset_config(asset_config);
            self.asset_configs.write(params.asset, asset_config);

            // set the interest rate model configuration
            self.interest_rate_model.set_interest_rate_config(params.asset, interest_rate_config);

            // set the oracle config
            self
                .pragma_oracle
                .set_oracle_config(
                    params.asset,
                    OracleConfig {
                        pragma_key: pragma_oracle_params.pragma_key,
                        timeout: pragma_oracle_params.timeout,
                        number_of_sources: pragma_oracle_params.number_of_sources,
                        start_time_offset: pragma_oracle_params.start_time_offset,
                        time_window: pragma_oracle_params.time_window,
                        aggregation_mode: pragma_oracle_params.aggregation_mode,
                    },
                );

            // Burn inflation fee.
            transfer_asset(asset.contract_address, caller, get_contract_address(), INFLATION_FEE, params.is_legacy);

            self.emit(SetAssetConfig { asset: params.asset });
        }

        /// Sets a parameter of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_asset_parameter(ref self: ContractState, asset: ContractAddress, parameter: felt252, value: u256) {
            let caller_address = get_caller_address();
            assert!(
                caller_address == self.extension_owner.read() || caller_address == self.extension.read(),
                "caller-not-extension-owner",
            );

            let mut asset_config = self.asset_config(asset);

            if parameter == 'max_utilization' {
                asset_config.max_utilization = value;
            } else if parameter == 'floor' {
                asset_config.floor = value;
            } else if parameter == 'fee_rate' {
                asset_config.fee_rate = value;
            } else {
                panic!("invalid-asset-parameter");
            }

            assert_asset_config(asset_config);
            assert_storable_asset_config(asset_config);
            self.asset_configs.write(asset, asset_config);

            self.emit(SetAssetParameter { asset, parameter, value });
        }

        /// Attributes the outstanding fee shares to the extension
        /// # Arguments
        /// * `asset` - address of the asset
        fn update_fee_shares(ref self: ContractState, asset: ContractAddress) {
            let asset_config = self.asset_config(asset);
            self.asset_configs.write(asset, asset_config);
        }

        /// Claims the fees accrued in the extension for a given asset and sends them to the fee recipient
        /// # Arguments
        /// * `asset` - address of the asset
        fn claim_fees(ref self: ContractState, asset: ContractAddress) {
            self.pausable.assert_not_paused();

            let mut asset_config = self.asset_config(asset);
            let fee_shares = asset_config.fee_shares;

            // Zero out the stored fee shares for the asset.
            asset_config.fee_shares = 0;

            // Write the updated asset config back to storage.
            self.asset_configs.write(asset, asset_config);

            // Convert shares to amount (round down).
            let amount = calculate_collateral(fee_shares, asset_config, false);
            let fee_recipient = self.fee_config.read().fee_recipient;

            IERC20Dispatcher { contract_address: asset }.transfer(fee_recipient, amount);

            self.emit(ClaimFees { asset, recipient: fee_recipient, amount });
        }

        /// Returns the number of unclaimed fee shares and the corresponding amount.
        fn get_fees(self: @ContractState, asset: ContractAddress) -> (u256, u256) {
            let asset_config = self.asset_config(asset);
            let fee_shares = asset_config.fee_shares;

            // Convert shares to amount (round down).
            let amount = calculate_collateral(fee_shares, asset_config, false);

            (fee_shares, amount)
        }

        /// Returns the fee configuration
        /// # Returns
        /// * `fee_config` - fee configuration
        fn fee_config(self: @ContractState) -> FeeConfig {
            self.fee_config.read()
        }

        /// Sets the fee configuration.
        /// # Arguments
        /// * `fee_config` - new fee configuration parameters
        fn set_fee_config(ref self: ContractState, fee_config: FeeConfig) {
            assert!(get_caller_address() == self.extension_owner.read(), "caller-not-owner");
            self.fee_config.write(fee_config);
            self.emit(SetFeeConfig { fee_config });
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

        /// Sets a parameter for a given oracle configuration of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_oracle_parameter(ref self: ContractState, asset: ContractAddress, parameter: felt252, value: felt252) {
            assert!(get_caller_address() == self.extension_owner.read(), "caller-not-extension-owner");
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

        /// Returns the interest rate configuration for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `interest_rate_config` - interest rate configuration
        fn interest_rate_config(self: @ContractState, asset: ContractAddress) -> InterestRateConfig {
            self.interest_rate_model.interest_rate_configs.read(asset)
        }

        /// Sets a parameter for a given interest rate configuration for an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_interest_rate_parameter(
            ref self: ContractState, asset: ContractAddress, parameter: felt252, value: u256,
        ) {
            assert!(get_caller_address() == self.extension_owner.read(), "caller-not-extension-owner");
            self.update_fee_shares(asset);
            self.interest_rate_model.set_interest_rate_parameter(asset, parameter, value);
        }

        /// Returns the address of the shutdown mode agent
        /// # Returns
        /// * `shutdown_mode_agent` - address of the shutdown mode agent
        fn shutdown_mode_agent(self: @ContractState) -> ContractAddress {
            self.shutdown_mode_agent.read()
        }

        /// Sets the shutdown mode agent
        /// # Arguments
        /// * `shutdown_mode_agent` - address of the shutdown mode agent
        fn set_shutdown_mode_agent(ref self: ContractState, shutdown_mode_agent: ContractAddress) {
            assert!(get_caller_address() == self.extension_owner.read(), "caller-not-extension-owner");
            self.shutdown_mode_agent.write(shutdown_mode_agent);
            self.emit(SetShutdownModeAgent { agent: shutdown_mode_agent });
        }

        /// Returns the name of the contract
        /// # Returns
        /// * `name` - the name of the contract
        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu Singleton'
        }

        /// Upgrades the contract to a new implementation
        /// # Arguments
        /// * `new_implementation` - the new implementation class hash
        fn upgrade(ref self: ContractState, new_implementation: ClassHash) {
            self.ownable.assert_only_owner();
            replace_class_syscall(new_implementation).unwrap();
            // Check to prevent mistakes when upgrading the contract
            let new_name = ISingletonV2Dispatcher { contract_address: get_contract_address() }.upgrade_name();
            assert(new_name == self.upgrade_name(), 'invalid upgrade name');
            self.emit(ContractUpgraded { new_implementation });
        }
    }

    #[abi(embed_v0)]
    pub impl PausableImpl of IPausable<ContractState> {
        fn is_paused(self: @ContractState) -> bool {
            self.pausable.is_paused()
        }

        fn pause(ref self: ContractState) {
            assert!(get_caller_address() == self.pauser.read(), "caller-not-pauser");
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            assert!(get_caller_address() == self.pauser.read(), "caller-not-pauser");
            self.pausable.unpause();
        }
    }
}
