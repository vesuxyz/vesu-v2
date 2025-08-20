use alexandria_math::i257::i257;
use starknet::{ClassHash, ContractAddress};
use vesu::data_model::{
    Amount, AssetConfig, AssetParams, Context, LTVConfig, LiquidatePositionParams, LiquidationConfig,
    ModifyPositionParams, Pair, Position, ShutdownConfig, ShutdownMode, ShutdownStatus, UpdatePositionResponse,
};
use vesu::interest_rate_model::InterestRateConfig;

#[starknet::interface]
pub trait IFlashLoanReceiver<TContractState> {
    fn on_flash_loan(
        ref self: TContractState, sender: ContractAddress, asset: ContractAddress, amount: u256, data: Span<felt252>,
    );
}

#[starknet::interface]
pub trait IPool<TContractState> {
    fn pool_name(self: @TContractState) -> felt252;
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
    fn add_asset(ref self: TContractState, params: AssetParams, interest_rate_config: InterestRateConfig);
    fn set_ltv_config(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, ltv_config: LTVConfig,
    );
    fn set_asset_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: u256);
    fn claim_fees(ref self: TContractState, asset: ContractAddress);
    fn get_fees(self: @TContractState, asset: ContractAddress) -> (u256, u256);
    fn fee_recipient(self: @TContractState) -> ContractAddress;
    fn set_fee_recipient(ref self: TContractState, fee_recipient: ContractAddress);
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
    fn oracle(self: @TContractState) -> ContractAddress;
    fn curator(self: @TContractState) -> ContractAddress;
    fn pending_curator(self: @TContractState) -> ContractAddress;
    fn nominate_curator(ref self: TContractState, pending_curator: ContractAddress);
    fn accept_curator_ownership(ref self: TContractState);

    fn debt_caps(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> u256;
    fn liquidation_config(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> LiquidationConfig;
    fn shutdown_config(self: @TContractState) -> ShutdownConfig;
    fn shutdown_status(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> ShutdownStatus;
    fn pairs(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> Pair;
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
    fn set_shutdown_mode(ref self: TContractState, new_shutdown_mode: ShutdownMode);
    fn update_shutdown_status(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> ShutdownMode;

    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn is_paused(self: @TContractState) -> bool;

    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(
        ref self: TContractState,
        new_implementation: ClassHash,
        eic_implementation_data: Option<(ClassHash, Span<felt252>)>,
    );
}

#[starknet::interface]
pub trait IEIC<TContractState> {
    fn eic_initialize(ref self: TContractState, data: Span<felt252>);
}


#[starknet::contract]
mod Pool {
    use alexandria_math::i257::{I257Trait, i257};
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use vesu::common::{
        apply_position_update_to_context, calculate_collateral, calculate_collateral_and_debt_value,
        calculate_collateral_shares, calculate_debt, calculate_fee_shares, calculate_nominal_debt,
        calculate_utilization, deconstruct_collateral_amount, deconstruct_debt_amount, is_collateralized,
    };
    use vesu::data_model::{
        Amount, AmountDenomination, AssetConfig, AssetParams, AssetPrice, Context, LTVConfig, LiquidatePositionParams,
        LiquidationConfig, ModifyPositionParams, Pair, Position, ShutdownConfig, ShutdownMode, ShutdownState,
        ShutdownStatus, UpdatePositionResponse, assert_asset_config, assert_asset_config_exists, assert_ltv_config,
    };
    use vesu::interest_rate_model::interest_rate_model_component::InterestRateModelTrait;
    use vesu::interest_rate_model::{InterestRateConfig, interest_rate_model_component};
    use vesu::math::pow_10;
    use vesu::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use vesu::packing::{AssetConfigPacking, PositionPacking, assert_storable_asset_config};
    use vesu::pool::{
        IEICDispatcherTrait, IEICLibraryDispatcher, IFlashLoanReceiverDispatcher, IFlashLoanReceiverDispatcherTrait,
        IPool, IPoolDispatcher, IPoolDispatcherTrait,
    };
    use vesu::units::{INFLATION_FEE, SCALE};

    #[storage]
    struct Storage {
        // tracks the name
        pool_name: felt252,
        // The owner of the pool
        curator: ContractAddress,
        // The pending curator
        pending_curator: ContractAddress,
        // Indicates whether the contract is paused
        paused: bool,
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
        // fee recipient
        fee_recipient: ContractAddress,
        // tracks the address that can transition the shutdown mode
        shutdown_mode_agent: ContractAddress,
        // contains the shutdown configuration
        shutdown_config: ShutdownConfig,
        // contains the current shutdown mode
        fixed_shutdown_mode: ShutdownState,
        // contains the liquidation configuration for each pair
        // (collateral_asset, debt_asset) -> liquidation configuration
        liquidation_configs: Map<(ContractAddress, ContractAddress), LiquidationConfig>,
        // tracks the total collateral shares and the total nominal debt for each pair
        // (collateral asset, debt asset) -> pair configuration
        pairs: Map<(ContractAddress, ContractAddress), Pair>,
        // tracks the debt caps for each asset
        debt_caps: Map<(ContractAddress, ContractAddress), u256>,
        // Oracle contract address
        oracle: ContractAddress,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
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
    struct ContractPaused {
        account: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ContractUnpaused {
        account: ContractAddress,
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
    pub struct SetFeeRecipient {
        #[key]
        fee_recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SetShutdownModeAgent {
        #[key]
        agent: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetLiquidationConfig {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        liquidation_config: LiquidationConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetShutdownConfig {
        shutdown_config: ShutdownConfig,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetShutdownMode {
        shutdown_mode: ShutdownMode,
        last_updated: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetDebtCap {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        debt_cap: u256,
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

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
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
        ContractPaused: ContractPaused,
        ContractUnpaused: ContractUnpaused,
        ContractUpgraded: ContractUpgraded,
        ClaimFees: ClaimFees,
        SetFeeRecipient: SetFeeRecipient,
        SetShutdownModeAgent: SetShutdownModeAgent,
        SetLiquidationConfig: SetLiquidationConfig,
        SetShutdownConfig: SetShutdownConfig,
        SetShutdownMode: SetShutdownMode,
        SetDebtCap: SetDebtCap,
        SetCurator: SetCurator,
        NominateCurator: NominateCurator,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: interest_rate_model_component, storage: interest_rate_model, event: InterestRateModelEvents);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        owner: ContractAddress,
        curator: ContractAddress,
        oracle: ContractAddress,
    ) {
        self.pool_name.write(name);
        self.ownable.initializer(owner);
        assert!(curator.is_non_zero(), "invalid-zero-curator");
        self.curator.write(curator);
        self.pending_curator.write(Zero::zero());
        self.paused.write(false);
        self.oracle.write(oracle);
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
        /// Asserts that the contract is not paused
        fn assert_not_paused(self: @ContractState) {
            assert!(!self.paused.read(), "contract-paused");
        }

        /// Asserts that the caller is either:
        /// 1. the owner of the position, or
        /// 2. a delegatee of the owner of the position
        fn assert_ownership(ref self: ContractState, position_user: ContractAddress) {
            let has_delegation = self.delegations.read((position_user, get_caller_address()));
            assert!(position_user == get_caller_address() || has_delegation, "no-delegation");
        }

        /// Asserts that the current utilization of an asset is below the max. allowed utilization
        fn assert_max_utilization(ref self: ContractState, asset_config: AssetConfig) {
            if self.fixed_shutdown_mode.read().shutdown_mode != ShutdownMode::None {
                return;
            }
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
            }
            if collateral_delta < Zero::zero() {
                // max. utilization of the collateral is not exceed
                self.assert_max_utilization(context.collateral_asset_config);
            }
            if debt_delta > Zero::zero() {
                // max. utilization of the collateral is not exceed
                self.assert_max_utilization(context.debt_asset_config);
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
                // value of the collateral is above the floor
                assert!(collateral_value > context.collateral_asset_config.floor, "dusty-collateral-balance");
            }

            // value of the outstanding debt is either zero or above the floor
            assert!(debt_value == 0 || debt_value > context.debt_asset_config.floor, "dusty-debt-balance");
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
        /// * `asset` - address of the asset
        /// * `asset_config` - asset config containing the previous rate accumulator and full utilization rate
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

        /// Updates the tracked total collateral shares and the total nominal debt assigned to a specific pair.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral_shares_delta` - collateral shares balance delta of the position
        /// * `nominal_debt_delta` - nominal debt balance delta of the position
        fn update_pair(
            ref self: ContractState, context: Context, collateral_shares_delta: i257, nominal_debt_delta: i257,
        ) {
            // update the balances of the pair of the modified position
            let Pair {
                mut total_collateral_shares, mut total_nominal_debt,
            } = self.pairs.read((context.collateral_asset, context.debt_asset));
            if collateral_shares_delta > Zero::zero() {
                total_collateral_shares = total_collateral_shares + collateral_shares_delta.abs();
            } else if collateral_shares_delta < Zero::zero() {
                total_collateral_shares = total_collateral_shares - collateral_shares_delta.abs();
            }
            if nominal_debt_delta > Zero::zero() {
                total_nominal_debt = total_nominal_debt + nominal_debt_delta.abs();
                let debt_cap = self.debt_caps.read((context.collateral_asset, context.debt_asset));
                if debt_cap != 0 {
                    let total_debt = calculate_debt(
                        total_nominal_debt,
                        context.debt_asset_config.last_rate_accumulator,
                        context.debt_asset_config.scale,
                        true,
                    );
                    assert!(total_debt <= debt_cap, "debt-cap-exceeded");
                }
            } else if nominal_debt_delta < Zero::zero() {
                total_nominal_debt = total_nominal_debt - nominal_debt_delta.abs();
            }
            self
                .pairs
                .write(
                    (context.collateral_asset, context.debt_asset),
                    Pair { total_collateral_shares, total_nominal_debt },
                );
        }

        /// Transitions into recovery mode if a pair is violating the constraints
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// # Returns
        /// * `shutdown_mode` - the shutdown mode
        fn _update_shutdown_status(ref self: ContractState, context: Context) -> ShutdownMode {
            // check if the shutdown mode has been overwritten
            let ShutdownState { shutdown_mode, .. } = self.fixed_shutdown_mode.read();

            // check if the shutdown mode has been set to a non-none value
            if shutdown_mode != ShutdownMode::None {
                return shutdown_mode;
            }

            let ShutdownStatus { shutdown_mode, violating } = self._shutdown_status(context);

            // if there is a current violation and no timestamp exists for the pair, then set the it (recovery)
            if violating {
                self.fixed_shutdown_mode.write(ShutdownState { shutdown_mode, last_updated: get_block_timestamp() });
            }

            shutdown_mode
        }

        /// Note: In order to get the shutdown status for the entire pool, this function needs to be called on all
        /// pairs associated with the pool.
        /// The furthest progressed shutdown mode for a pair is the shutdown mode of the pool.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// # Returns
        /// * `shutdown_status` - shutdown status of the pool
        fn _shutdown_status(self: @ContractState, context: Context) -> ShutdownStatus {
            // if pool is in either subscription period, redemption period, then return mode
            let ShutdownState { mut shutdown_mode, .. } = self.fixed_shutdown_mode.read();

            // check oracle status
            let invalid_oracle = !context.collateral_asset_price.is_valid || !context.debt_asset_price.is_valid;

            // check rate accumulator values
            let collateral_accumulator = context.collateral_asset_config.last_rate_accumulator;
            let debt_accumulator = context.debt_asset_config.last_rate_accumulator;
            let safe_rate_accumulator = collateral_accumulator < 18 * SCALE && debt_accumulator < 18 * SCALE;

            // either the oracle price is invalid or unsafe rate accumulator
            let violating = invalid_oracle || !safe_rate_accumulator;

            // set shutdown mode to recovery if there is a violation and the shutdown mode is not set already
            if shutdown_mode == ShutdownMode::None && violating {
                shutdown_mode = ShutdownMode::Recovery;
            }

            ShutdownStatus { shutdown_mode, violating }
        }

        /// Implements logic to execute before a position gets liquidated.
        /// Liquidations are only allowed in normal and recovery mode. The liquidator has to be specify how much
        /// debt to repay and the minimum amount of collateral to receive in exchange. The value of the collateral
        /// is discounted by the liquidation factor in comparison to the current price (according to the oracle).
        /// In an event where there's not enough collateral to cover the debt, the liquidation will result in bad debt.
        /// The bad debt is attributed to the pool and distributed amongst the lenders of the corresponding
        /// collateral asset. The liquidator receives all the collateral but only has to repay the proportioned
        /// debt value.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `min_collateral_to_receive` - minimum amount of collateral to be received
        /// * `debt_to_repay` - amount of debt to be repaid
        /// # Returns
        /// * `collateral` - amount of collateral to be removed
        /// * `debt` - amount of debt to be removed
        /// * `bad_debt` - amount of bad debt accrued during the liquidation
        fn compute_liquidation_amounts(
            ref self: ContractState, context: Context, min_collateral_to_receive: u256, mut debt_to_repay: u256,
        ) -> (u256, u256, u256) {
            // compute the collateral and debt value of the position
            let (collateral, mut collateral_value, debt, debt_value) = calculate_collateral_and_debt_value(
                context, context.position,
            );

            // if the liquidation factor is not set, then set it to 100%
            let liquidation_config: LiquidationConfig = self
                .liquidation_configs
                .read((context.collateral_asset, context.debt_asset));
            let liquidation_factor = if liquidation_config.liquidation_factor == 0 {
                SCALE
            } else {
                liquidation_config.liquidation_factor.into()
            };

            // limit debt to repay by the position's outstanding debt
            debt_to_repay = if debt_to_repay > debt {
                debt
            } else {
                debt_to_repay
            };

            // apply liquidation factor to debt value to get the collateral amount to release
            let collateral_value_to_receive = u256_mul_div(
                debt_to_repay, context.debt_asset_price.value, context.debt_asset_config.scale, Rounding::Floor,
            );
            let mut collateral_to_receive = u256_mul_div(
                u256_mul_div(collateral_value_to_receive, SCALE, context.collateral_asset_price.value, Rounding::Floor),
                context.collateral_asset_config.scale,
                liquidation_factor,
                Rounding::Floor,
            );

            // limit collateral to receive by the position's remaining collateral balance
            collateral_to_receive = if collateral_to_receive > collateral {
                collateral
            } else {
                collateral_to_receive
            };

            // apply liquidation factor to collateral value
            collateral_value = u256_mul_div(collateral_value, liquidation_factor, SCALE, Rounding::Floor);

            // check that a min. amount of collateral is released
            assert!(collateral_to_receive >= min_collateral_to_receive, "less-than-min-collateral");

            // account for bad debt if there isn't enough collateral to cover the debt
            let mut bad_debt = 0;
            if collateral_value < debt_value {
                // limit the bad debt by the outstanding collateral and debt values (in usd)
                if collateral_value < u256_mul_div(
                    debt_to_repay, context.debt_asset_price.value, context.debt_asset_config.scale, Rounding::Ceil,
                ) {
                    bad_debt =
                        u256_mul_div(
                            debt_value - collateral_value,
                            context.debt_asset_config.scale,
                            context.debt_asset_price.value,
                            Rounding::Floor,
                        );
                    debt_to_repay = debt;
                } else {
                    // derive the bad debt proportionally to the debt repaid
                    bad_debt =
                        u256_mul_div(debt_to_repay, debt_value - collateral_value, collateral_value, Rounding::Ceil);
                    debt_to_repay = debt_to_repay + bad_debt;
                }
            }

            (collateral_to_receive, debt_to_repay, bad_debt)
        }
    }

    #[abi(embed_v0)]
    impl PoolImpl of IPool<ContractState> {
        /// Returns the name of a pool
        /// # Returns
        /// * `name` - name of the pool
        fn pool_name(self: @ContractState) -> felt252 {
            self.pool_name.read()
        }

        /// Returns the configuration / state of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `asset_config` - asset configuration
        fn asset_config(self: @ContractState, asset: ContractAddress) -> AssetConfig {
            let mut asset_config = self.asset_configs.read(asset);
            // Check that the asset is registered.
            assert_asset_config_exists(asset_config);

            if asset_config.last_updated != get_block_timestamp() {
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

        /// Loads the contextual state for a given user. This includes the state of the
        /// collateral and debt assets, loan-to-value configurations and the state of the position.
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

            let collateral_asset_config = self.asset_config(collateral_asset);
            let debt_asset_config = self.asset_config(debt_asset);

            let oracle = IOracleDispatcher { contract_address: self.oracle.read() };
            Context {
                collateral_asset,
                debt_asset,
                collateral_asset_config,
                debt_asset_config,
                collateral_asset_price: oracle.price(collateral_asset),
                debt_asset_price: oracle.price(debt_asset),
                max_ltv: self.ltv_configs.read((collateral_asset, debt_asset)).max_ltv,
                user,
                position: self.positions.read((collateral_asset, debt_asset, user)),
            }
        }

        /// Adjusts a positions collateral and debt balances
        /// # Arguments
        /// * `params` - see ModifyPositionParams
        /// # Returns
        /// * `response` - see UpdatePositionResponse
        fn modify_position(ref self: ContractState, params: ModifyPositionParams) -> UpdatePositionResponse {
            self.assert_not_paused();

            let ModifyPositionParams { collateral_asset, debt_asset, user, collateral, debt } = params;

            // caller owns the position or has a delegate for modifying it
            self.assert_ownership(user);

            let mut context = self.context(collateral_asset, debt_asset, user);

            // update the position
            let response = self.update_position(ref context, collateral, debt, 0);
            let UpdatePositionResponse {
                collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, ..,
            } = response;

            // verify invariants
            self.assert_position_invariants(context, collateral_delta, debt_delta);

            self.update_pair(context, collateral_shares_delta, nominal_debt_delta);

            let shutdown_mode = self._update_shutdown_status(context);

            // check invariants for collateral and debt amounts
            if shutdown_mode == ShutdownMode::Recovery {
                let decreasing_collateral = collateral_delta < Zero::zero();
                let increasing_debt = debt_delta > Zero::zero();
                assert!(!(decreasing_collateral || increasing_debt), "in-recovery");
            } else if shutdown_mode == ShutdownMode::Subscription {
                let modifying_collateral = collateral_delta != Zero::zero();
                let increasing_debt = debt_delta > Zero::zero();
                assert!(!(modifying_collateral || increasing_debt), "in-subscription");
            } else if shutdown_mode == ShutdownMode::Redemption {
                let increasing_collateral = collateral_delta > Zero::zero();
                let modifying_debt = debt_delta != Zero::zero();
                assert!(!(increasing_collateral || modifying_debt), "in-redemption");
                assert!(context.position.nominal_debt == 0, "non-zero-debt");
            }

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
            self.assert_not_paused();

            let LiquidatePositionParams {
                collateral_asset, debt_asset, user, min_collateral_to_receive, debt_to_repay, ..,
            } = params;

            let mut context = self.context(collateral_asset, debt_asset, user);

            // don't allow for liquidations if the pool is not in normal mode
            let shutdown_mode = self._update_shutdown_status(context);
            assert!(shutdown_mode == ShutdownMode::None, "emergency-mode");

            let (collateral, debt, bad_debt) = self
                .compute_liquidation_amounts(context, min_collateral_to_receive, debt_to_repay);

            // convert unsigned amounts to signed amounts
            let collateral = Amount {
                denomination: AmountDenomination::Assets, value: I257Trait::new(collateral, true),
            };
            let debt = Amount { denomination: AmountDenomination::Assets, value: I257Trait::new(debt, true) };

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

            self.update_pair(context, collateral_shares_delta, nominal_debt_delta);

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
        /// * `is_legacy` - whether the asset is using legacy naming conventions
        /// * `data` - data to pass to the flash loan receiver
        fn flash_loan(
            ref self: ContractState,
            receiver: ContractAddress,
            asset: ContractAddress,
            amount: u256,
            is_legacy: bool,
            data: Span<felt252>,
        ) {
            self.assert_not_paused();

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
            self.assert_not_paused();

            self.delegations.write((get_caller_address(), delegatee), delegation);

            self.emit(ModifyDelegation { delegator: get_caller_address(), delegatee, delegation });
        }

        /// Donates an amount of an asset to the pool's reserve
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `amount` - amount to donate [asset scale]
        fn donate_to_reserve(ref self: ContractState, asset: ContractAddress, amount: u256) {
            self.assert_not_paused();

            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
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
            self.assert_not_paused();

            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            assert!(collateral_asset != debt_asset, "identical-assets");
            assert_ltv_config(ltv_config);

            self.ltv_configs.write((collateral_asset, debt_asset), ltv_config);

            self.emit(SetLTVConfig { collateral_asset, debt_asset, ltv_config });
        }

        /// Adds a new asset to the pool
        /// This function assumes that the oracle config was already set up for the asset.
        /// # Arguments
        /// * `params` - see AssetParams
        fn add_asset(ref self: ContractState, params: AssetParams, interest_rate_config: InterestRateConfig) {
            self.assert_not_paused();

            let caller = get_caller_address();
            assert!(caller == self.curator.read(), "caller-not-curator");
            assert!(self.asset_configs.read(params.asset).scale == 0, "asset-config-already-exists");

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

            // Check that oracle of the given asset was set.
            let oracle = IOracleDispatcher { contract_address: self.oracle.read() };
            assert!(oracle.price(params.asset).is_valid, "oracle-price-invalid");

            assert_asset_config(asset_config);
            assert_storable_asset_config(asset_config);
            self.asset_configs.write(params.asset, asset_config);

            // set the interest rate model configuration
            self.interest_rate_model.set_interest_rate_config(params.asset, interest_rate_config);

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
            self.assert_not_paused();

            let caller_address = get_caller_address();
            assert!(caller_address == self.curator.read(), "caller-not-curator");

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

        /// Claims the fees accrued in the pool for a given asset and sends them to the fee recipient
        /// # Arguments
        /// * `asset` - address of the asset
        fn claim_fees(ref self: ContractState, asset: ContractAddress) {
            self.assert_not_paused();

            let mut asset_config = self.asset_config(asset);
            let fee_shares = asset_config.fee_shares;

            // Zero out the stored fee shares for the asset.
            asset_config.fee_shares = 0;

            // Write the updated asset config back to storage.
            self.asset_configs.write(asset, asset_config);

            // Convert shares to amount (round down).
            let amount = calculate_collateral(fee_shares, asset_config, false);
            let fee_recipient = self.fee_recipient.read();

            assert!(
                IERC20Dispatcher { contract_address: asset }.transfer(fee_recipient, amount), "fee-transfer-failed",
            );

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

        /// Returns the address to which fees are sent
        /// # Returns
        /// fee recipient address
        fn fee_recipient(self: @ContractState) -> ContractAddress {
            self.fee_recipient.read()
        }

        /// Sets the address to which fees are sent.
        /// # Arguments
        /// * `fee_recipient` - new fee address
        fn set_fee_recipient(ref self: ContractState, fee_recipient: ContractAddress) {
            self.assert_not_paused();
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");

            self.fee_recipient.write(fee_recipient);
            self.emit(SetFeeRecipient { fee_recipient });
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
            self.assert_not_paused();

            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            let asset_config = self.asset_config(asset);
            self.asset_configs.write(asset, asset_config);
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
            self.assert_not_paused();

            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            self.shutdown_mode_agent.write(shutdown_mode_agent);
            self.emit(SetShutdownModeAgent { agent: shutdown_mode_agent });
        }

        /// Returns the debt cap for a given asset
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `debt_cap` - debt cap
        fn debt_caps(self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> u256 {
            self.debt_caps.read((collateral_asset, debt_asset))
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
            self.liquidation_configs.read((collateral_asset, debt_asset))
        }

        /// Returns the shutdown configuration
        /// # Returns
        /// * `recovery_period` - recovery period
        /// * `subscription_period` - subscription period
        fn shutdown_config(self: @ContractState) -> ShutdownConfig {
            self.shutdown_config.read()
        }

        /// Returns the total (sum of all positions) collateral shares and nominal debt balances for a given pair
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `total_collateral_shares` - total collateral shares
        /// * `total_nominal_debt` - total nominal debt
        fn pairs(self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> Pair {
            self.pairs.read((collateral_asset, debt_asset))
        }

        /// Sets the debt cap for a given asset
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `debt_cap` - debt cap
        fn set_debt_cap(
            ref self: ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, debt_cap: u256,
        ) {
            self.assert_not_paused();

            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            self.debt_caps.write((collateral_asset, debt_asset), debt_cap);
            self.emit(SetDebtCap { collateral_asset, debt_asset, debt_cap });
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
            self.assert_not_paused();

            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            assert!(liquidation_config.liquidation_factor.into() <= SCALE, "invalid-liquidation-config");

            self
                .liquidation_configs
                .write(
                    (collateral_asset, debt_asset),
                    LiquidationConfig {
                        liquidation_factor: if liquidation_config.liquidation_factor == 0 {
                            SCALE.try_into().unwrap()
                        } else {
                            liquidation_config.liquidation_factor
                        },
                    },
                );

            self.emit(SetLiquidationConfig { collateral_asset, debt_asset, liquidation_config });
        }

        /// Sets the shutdown config
        /// # Arguments
        /// * `shutdown_config` - shutdown config
        fn set_shutdown_config(ref self: ContractState, shutdown_config: ShutdownConfig) {
            self.assert_not_paused();

            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            self.shutdown_config.write(shutdown_config);
            self.emit(SetShutdownConfig { shutdown_config });
        }

        /// Sets the shutdown mode and overwrites the inferred shutdown mode
        /// # Arguments
        /// * `shutdown_mode` - shutdown mode
        fn set_shutdown_mode(ref self: ContractState, new_shutdown_mode: ShutdownMode) {
            self.assert_not_paused();

            let shutdown_mode_agent = self.shutdown_mode_agent();
            assert!(
                get_caller_address() == self.curator.read() || get_caller_address() == shutdown_mode_agent,
                "caller-not-curator-or-agent",
            );
            assert!(
                get_caller_address() != shutdown_mode_agent || new_shutdown_mode == ShutdownMode::Recovery,
                "shutdown-mode-not-recovery",
            );

            let ShutdownState { shutdown_mode, last_updated, .. } = self.fixed_shutdown_mode.read();

            match shutdown_mode {
                ShutdownMode::None => {
                    // can only transition to recovery mode
                    assert!(new_shutdown_mode == ShutdownMode::Recovery, "shutdown-mode-not-none");
                },
                ShutdownMode::Recovery => {
                    // can only transition back to normal mode or subscription mode
                    assert!(
                        new_shutdown_mode == ShutdownMode::None || new_shutdown_mode == ShutdownMode::Subscription,
                        "shutdown-mode-not-recovery",
                    );
                },
                ShutdownMode::Subscription => {
                    // can only transition to redemption mode
                    assert!(new_shutdown_mode == ShutdownMode::Redemption, "shutdown-mode-not-subscription");
                },
                ShutdownMode::Redemption => {
                    // can not transition into any shutdown mode
                    assert!(false, "shutdown-mode-in-redemption");
                },
            }

            let ShutdownConfig { recovery_period, subscription_period } = self.shutdown_config.read();

            // can only transition to subscription mode if the recovery period has passed
            assert!(
                new_shutdown_mode != ShutdownMode::Subscription || last_updated
                    + recovery_period < get_block_timestamp(),
                "shutdown-mode-recovery-period",
            );

            // can only transition to redemption mode if the subscription period has passed
            assert!(
                new_shutdown_mode != ShutdownMode::Redemption || last_updated
                    + subscription_period < get_block_timestamp(),
                "shutdown-mode-subscription-period",
            );

            let shutdown_state = ShutdownState {
                shutdown_mode: new_shutdown_mode, last_updated: get_block_timestamp(),
            };
            self.fixed_shutdown_mode.write(shutdown_state);

            self.emit(SetShutdownMode { shutdown_mode: new_shutdown_mode, last_updated: shutdown_state.last_updated });
        }

        /// Returns the shutdown mode for a specific pair.
        /// To check the shutdown status of the pool, the shutdown mode for all pairs must be checked.
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
            let context = self.context(collateral_asset, debt_asset, Zero::zero());
            self._shutdown_status(context)
        }

        /// Updates the shutdown mode for a specific pair.
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `shutdown_mode` - shutdown mode
        fn update_shutdown_status(
            ref self: ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> ShutdownMode {
            self.assert_not_paused();

            let caller = get_caller_address();
            assert!(
                caller == self.curator.read() || caller == self.shutdown_mode_agent.read(),
                "caller-not-curator-or-agent",
            );

            let context = self.context(collateral_asset, debt_asset, Zero::zero());
            self._update_shutdown_status(context)
        }

        /// Returns the address of the oracle
        /// # Returns
        /// * `oracle` - address of the oracle
        fn oracle(self: @ContractState) -> ContractAddress {
            self.oracle.read()
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

        /// Pauses the contract
        ///
        /// Requirements:
        ///
        /// - The contract is not paused.
        ///
        /// Emits a `Paused` event.
        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            assert!(!self.paused.read(), "contract-already-paused");
            self.paused.write(true);
            self.emit(ContractPaused { account: get_caller_address() });
        }

        /// Lifts the pause on the contract.
        ///
        /// Requirements:
        ///
        /// - The contract is paused.
        ///
        /// Emits an `Unpaused` event.
        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            assert!(self.paused.read(), "contract-already-unpaused");
            self.paused.write(false);
            self.emit(ContractUnpaused { account: get_caller_address() });
        }

        /// Returns true if the contract is paused, and false otherwise.
        fn is_paused(self: @ContractState) -> bool {
            self.paused.read()
        }

        /// Returns the name of the contract
        /// # Returns
        /// * `name` - the name of the contract
        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu Pool'
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
            let new_name = IPoolDispatcher { contract_address: get_contract_address() }.upgrade_name();
            assert(new_name == self.upgrade_name(), 'invalid upgrade name');
            self.emit(ContractUpgraded { new_implementation });
        }
    }
}
