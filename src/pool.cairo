use alexandria_math::i257::i257;
use starknet::{ClassHash, ContractAddress};
use vesu::data_model::{
    Amount, AssetConfig, AssetParams, AssetPrice, Context, LiquidatePositionParams, ModifyPositionParams, Pair,
    PairConfig, Position, UpdatePositionResponse,
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

    fn context(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> Context;
    fn position(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> (Position, u256, u256);
    fn check_collateralization(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> (bool, u256, u256);
    fn check_invariants(
        self: @TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        collateral_delta: i257,
        collateral_shares_delta: i257,
        debt_delta: i257,
        nominal_debt_delta: i257,
        is_liquidation: bool,
    );

    // Entrypoints
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
    fn delegation(self: @TContractState, delegator: ContractAddress, delegatee: ContractAddress) -> bool;
    fn donate_to_reserve(ref self: TContractState, asset: ContractAddress, amount: u256);

    // Asset Configuration
    fn add_asset(ref self: TContractState, params: AssetParams, interest_rate_config: InterestRateConfig);
    fn set_asset_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: u256);
    fn asset_config(self: @TContractState, asset: ContractAddress) -> AssetConfig;

    // Oracle
    fn set_oracle(ref self: TContractState, oracle: ContractAddress);
    fn oracle(self: @TContractState) -> ContractAddress;
    fn price(self: @TContractState, asset: ContractAddress) -> AssetPrice;

    // Fees
    fn set_fee_recipient(ref self: TContractState, fee_recipient: ContractAddress);
    fn fee_recipient(self: @TContractState) -> ContractAddress;
    fn claim_fees(ref self: TContractState, asset: ContractAddress, fee_shares: u256);
    fn get_fees(self: @TContractState, asset: ContractAddress) -> (u256, u256);

    // Interest Rate Model
    fn rate_accumulator(self: @TContractState, asset: ContractAddress) -> u256;
    fn utilization(self: @TContractState, asset: ContractAddress) -> u256;
    fn interest_rate(
        self: @TContractState,
        asset: ContractAddress,
        utilization: u256,
        last_updated: u64,
        last_full_utilization_rate: u256,
    ) -> u256;
    fn set_interest_rate_parameter(ref self: TContractState, asset: ContractAddress, parameter: felt252, value: u256);
    fn interest_rate_config(self: @TContractState, asset: ContractAddress) -> InterestRateConfig;

    // Pair Configuration
    fn pairs(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> Pair;
    fn set_pair_config(
        ref self: TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        pair_config: PairConfig,
    );
    fn set_pair_parameter(
        ref self: TContractState,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        parameter: felt252,
        value: u128,
    );
    fn pair_config(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> PairConfig;

    // Utility Functions
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

    // Curator
    fn curator(self: @TContractState) -> ContractAddress;
    fn pending_curator(self: @TContractState) -> ContractAddress;
    fn nominate_curator(ref self: TContractState, pending_curator: ContractAddress);
    fn accept_curator_ownership(ref self: TContractState);

    // Admin Functions
    fn set_pausing_agent(ref self: TContractState, pausing_agent: ContractAddress);
    fn pausing_agent(self: @TContractState) -> ContractAddress;
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn is_paused(self: @TContractState) -> bool;

    // Upgrade Functions
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
        Amount, AmountDenomination, AssetConfig, AssetParams, AssetPrice, Context, LiquidatePositionParams,
        ModifyPositionParams, Pair, PairConfig, Position, UpdatePositionResponse, assert_asset_config,
        assert_asset_config_exists, assert_pair_config,
    };
    use vesu::interest_rate_model::interest_rate_model_component::InterestRateModelTrait;
    use vesu::interest_rate_model::{InterestRateConfig, interest_rate_model_component};
    use vesu::math::pow_10;
    use vesu::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use vesu::packing::{
        AssetConfigPacking, PairPacking, PositionPacking, assert_storable_asset_config, assert_storable_pair_config,
    };
    use vesu::pool::{
        IEICDispatcherTrait, IEICLibraryDispatcher, IFlashLoanReceiverDispatcher, IFlashLoanReceiverDispatcherTrait,
        IPool, IPoolDispatcher, IPoolDispatcherTrait,
    };
    use vesu::units::{INFLATION_FEE, SCALE};

    #[storage]
    struct Storage {
        // tracks the name
        pool_name: felt252,
        // tracks the state of each position
        // (collateral_asset, debt_asset, user) -> position
        positions: Map<(ContractAddress, ContractAddress, ContractAddress), Position>,
        // tracks the delegation status for each delegator to a delegatee
        // (delegator, delegatee) -> delegation
        delegations: Map<(ContractAddress, ContractAddress), bool>,
        // tracks the configuration / state of each asset
        // asset -> asset configuration
        asset_configs: Map<ContractAddress, AssetConfig>,
        // Oracle contract address
        oracle: ContractAddress,
        // fee recipient
        fee_recipient: ContractAddress,
        // tracks the configuration / state of each pair
        // (collateral_asset, debt_asset) -> pair configuration
        pair_configs: Map<(ContractAddress, ContractAddress), PairConfig>,
        // tracks the total collateral shares and the total nominal debt for each pair
        // (collateral asset, debt asset) -> pair configuration
        pairs: Map<(ContractAddress, ContractAddress), Pair>,
        // tracks the address that can pause the contract
        pausing_agent: ContractAddress,
        // The owner of the pool
        curator: ContractAddress,
        // The pending curator
        pending_curator: ContractAddress,
        // Indicates whether the contract is paused
        paused: bool,
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
    struct SetAssetConfig {
        #[key]
        asset: ContractAddress,
        asset_config: AssetConfig,
    }

    #[derive(Drop, starknet::Event)]
    struct SetOracle {
        oracle: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SetPairConfig {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        pair_config: PairConfig,
    }

    #[derive(Drop, starknet::Event)]
    struct ClaimFees {
        #[key]
        asset: ContractAddress,
        recipient: ContractAddress,
        fee_shares: u256,
        fee_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SetFeeRecipient {
        #[key]
        fee_recipient: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SetPausingAgent {
        #[key]
        agent: ContractAddress,
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

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        InterestRateModelEvents: interest_rate_model_component::Event,
        UpdateContext: UpdateContext,
        ModifyPosition: ModifyPosition,
        LiquidatePosition: LiquidatePosition,
        Flashloan: Flashloan,
        ModifyDelegation: ModifyDelegation,
        Donate: Donate,
        SetAssetConfig: SetAssetConfig,
        SetOracle: SetOracle,
        SetPairConfig: SetPairConfig,
        ClaimFees: ClaimFees,
        SetFeeRecipient: SetFeeRecipient,
        SetPausingAgent: SetPausingAgent,
        SetCurator: SetCurator,
        NominateCurator: NominateCurator,
        ContractPaused: ContractPaused,
        ContractUnpaused: ContractUnpaused,
        ContractUpgraded: ContractUpgraded,
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
        fn assert_ownership(self: @ContractState, owner: ContractAddress) {
            let has_delegation = self.delegations.read((owner, get_caller_address()));
            assert!(owner == get_caller_address() || has_delegation, "no-delegation");
        }

        /// Asserts that the current utilization of an asset is below the max. allowed utilization
        fn assert_max_utilization(self: @ContractState, asset_config: AssetConfig) {
            assert!(utilization(asset_config) <= asset_config.max_utilization, "utilization-exceeded")
        }

        /// Asserts that the collateralization of a position is not above the max. loan-to-value ratio
        fn assert_collateralization(
            self: @ContractState, collateral_value: u256, debt_value: u256, max_ltv_ratio: u256,
        ) {
            assert!(is_collateralized(collateral_value, debt_value, max_ltv_ratio), "not-collateralized");
        }

        /// Asserts invariants a position has to fulfill at all times (excluding liquidations)
        fn assert_position_invariants(
            self: @ContractState, context: Context, collateral_delta: i257, debt_delta: i257,
        ) {
            if collateral_delta < Zero::zero() || debt_delta > Zero::zero() {
                // position is collateralized
                let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(
                    context, context.position,
                );
                self.assert_collateralization(collateral_value, debt_value, context.max_ltv.into());
                // caller owns the position or has a delegate for modifying it
                self.assert_ownership(context.user);
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
        fn assert_delta_invariants(
            self: @ContractState,
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
        fn assert_floor_invariant(self: @ContractState, context: Context) {
            let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(context, context.position);

            if context.position.nominal_debt != 0 {
                // value of the collateral is above the floor
                assert!(collateral_value > context.collateral_asset_config.floor, "dusty-collateral-balance");
            }

            // value of the outstanding debt is either zero or above the floor
            assert!(debt_value == 0 || debt_value > context.debt_asset_config.floor, "dusty-debt-balance");
        }

        /// Asserts that the debt cap is not exceeded for a pair
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        fn assert_debt_cap_invariant(self: @ContractState, context: Context) {
            let Pair { total_nominal_debt, .. } = self.pairs.read((context.collateral_asset, context.debt_asset));
            let PairConfig { debt_cap, .. } = self.pair_configs.read((context.collateral_asset, context.debt_asset));

            if debt_cap != 0 {
                let total_debt = calculate_debt(
                    total_nominal_debt,
                    context.debt_asset_config.last_rate_accumulator,
                    context.debt_asset_config.scale,
                    true,
                );
                assert!(total_debt <= debt_cap.into(), "debt-cap-exceeded");
            }
        }

        /// Asserts that the oracle prices are valid and that the rate accumulators are safe
        fn assert_security_invariants(self: @ContractState, context: Context) {
            // check oracle status
            let invalid_oracle = !context.collateral_asset_price.is_valid || !context.debt_asset_price.is_valid;
            assert!(!invalid_oracle, "invalid-oracle");

            // check rate accumulator values
            let collateral_accumulator = context.collateral_asset_config.last_rate_accumulator;
            let debt_accumulator = context.debt_asset_config.last_rate_accumulator;
            let safe_rate_accumulator = collateral_accumulator < 18 * SCALE && debt_accumulator < 18 * SCALE;
            assert!(safe_rate_accumulator, "unsafe-rate-accumulator");
        }

        /// Asserts that all invariants are met for a position
        fn assert_invariants(
            self: @ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            is_liquidation: bool,
        ) {
            if !is_liquidation {
                self.assert_position_invariants(context, collateral_delta, debt_delta);
            }
            self.assert_delta_invariants(collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta);
            self.assert_floor_invariant(context);
            self.assert_debt_cap_invariant(context);
            self.assert_security_invariants(context);
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

        /// Updates the balances of a pair
        fn update_pair(
            ref self: ContractState, context: Context, collateral_shares_delta: i257, nominal_debt_delta: i257,
        ) {
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

        /// Updates the state of a position and the corresponding collateral and debt asset
        fn update_position(
            ref self: ContractState,
            ref context: Context,
            collateral: Amount,
            debt: Amount,
            bad_debt: u256,
            is_liquidation: bool,
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

            // update the pair balances
            self.update_pair(context, collateral_shares_delta, nominal_debt_delta);

            // verify invariants
            self
                .assert_invariants(
                    context, collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, is_liquidation,
                );

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
            let PairConfig {
                liquidation_factor, ..,
            } = self.pair_configs.read((context.collateral_asset, context.debt_asset));
            let liquidation_factor = if liquidation_factor == 0 {
                SCALE
            } else {
                liquidation_factor.into()
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

            let PairConfig { max_ltv, .. } = self.pair_configs.read((collateral_asset, debt_asset));

            let oracle = IOracleDispatcher { contract_address: self.oracle.read() };
            Context {
                collateral_asset,
                debt_asset,
                collateral_asset_config,
                debt_asset_config,
                collateral_asset_price: oracle.price(collateral_asset),
                debt_asset_price: oracle.price(debt_asset),
                max_ltv,
                user,
                position: self.positions.read((collateral_asset, debt_asset, user)),
            }
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

        /// Asserts that all invariants are met for a position. Reverts if any invariant is not met.
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// * `collateral_delta` - collateral delta
        /// * `collateral_shares_delta` - collateral shares delta
        /// * `debt_delta` - debt delta
        /// * `nominal_debt_delta` - nominal debt delta
        /// * `is_liquidation` - whether the position is being liquidated
        fn check_invariants(
            self: @ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            is_liquidation: bool,
        ) {
            let context = self.context(collateral_asset, debt_asset, user);
            self
                .assert_invariants(
                    context, collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, is_liquidation,
                );
        }

        /// Adjusts a positions collateral and debt balances
        /// # Arguments
        /// * `params` - see ModifyPositionParams
        /// # Returns
        /// * `response` - see UpdatePositionResponse
        fn modify_position(ref self: ContractState, params: ModifyPositionParams) -> UpdatePositionResponse {
            self.assert_not_paused();

            let ModifyPositionParams { collateral_asset, debt_asset, user, collateral, debt } = params;

            let mut context = self.context(collateral_asset, debt_asset, user);

            // update the position
            let response = self.update_position(ref context, collateral, debt, 0, false);
            let UpdatePositionResponse {
                collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, ..,
            } = response;

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
            let response = self.update_position(ref context, collateral, debt, bad_debt, true);
            let UpdatePositionResponse {
                mut collateral_delta, mut collateral_shares_delta, debt_delta, nominal_debt_delta, bad_debt,
            } = response;

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

        /// Returns the delegation status of a delegator to a delegatee
        /// # Arguments
        /// * `delegator` - address of the delegator
        /// * `delegatee` - address of the delegatee
        /// # Returns
        /// * `delegation` - delegation status (true = delegate, false = undelegate)
        fn delegation(self: @ContractState, delegator: ContractAddress, delegatee: ContractAddress) -> bool {
            self.delegations.read((delegator, delegatee))
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
                last_rate_accumulator: SCALE,
                last_full_utilization_rate: params.initial_full_utilization_rate,
                fee_rate: params.fee_rate,
                fee_shares: 0,
            };

            // Check that oracle of the given asset was set
            let oracle = IOracleDispatcher { contract_address: self.oracle.read() };
            assert!(oracle.price(params.asset).is_valid, "oracle-price-invalid");

            assert_asset_config(asset_config);
            assert_storable_asset_config(asset_config);
            self.asset_configs.write(params.asset, asset_config);

            self.emit(SetAssetConfig { asset: params.asset, asset_config });

            // set the interest rate model configuration
            self.interest_rate_model.set_interest_rate_config(params.asset, interest_rate_config);

            // Burn inflation fee
            transfer_asset(asset.contract_address, caller, get_contract_address(), INFLATION_FEE, params.is_legacy);
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

            self.emit(SetAssetConfig { asset, asset_config });
        }

        /// Returns the configuration / state of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `asset_config` - asset configuration
        fn asset_config(self: @ContractState, asset: ContractAddress) -> AssetConfig {
            let mut asset_config = self.asset_configs.read(asset);

            // Check that the asset is registered
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

        /// Sets the address of the oracle
        /// # Arguments
        /// * `oracle` - address of the oracle
        fn set_oracle(ref self: ContractState, oracle: ContractAddress) {
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            self.oracle.write(oracle);
            self.emit(SetOracle { oracle });
        }

        /// Returns the address of the oracle
        /// # Returns
        /// * `oracle` - address of the oracle
        fn oracle(self: @ContractState) -> ContractAddress {
            self.oracle.read()
        }

        /// Returns the price of an asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `price` - price of the asset
        fn price(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            IOracleDispatcher { contract_address: self.oracle.read() }.price(asset)
        }

        /// Sets the address to which fees are sent
        /// # Arguments
        /// * `fee_recipient` - new fee address
        fn set_fee_recipient(ref self: ContractState, fee_recipient: ContractAddress) {
            self.assert_not_paused();
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");

            self.fee_recipient.write(fee_recipient);
            self.emit(SetFeeRecipient { fee_recipient });
        }

        /// Returns the address to which fees are sent
        /// # Returns
        /// fee recipient address
        fn fee_recipient(self: @ContractState) -> ContractAddress {
            self.fee_recipient.read()
        }

        /// Claims the fees accrued in the pool for a given asset and sends them to the fee recipient
        /// # Arguments
        /// * `asset` - address of the asset
        /// * `shares` - number of fee shares to claim (0 to claim all)
        fn claim_fees(ref self: ContractState, asset: ContractAddress, mut fee_shares: u256) {
            self.assert_not_paused();

            let mut asset_config = self.asset_config(asset);
            assert!(asset_config.fee_shares >= fee_shares, "insufficient-fee-shares");
            if fee_shares == 0 {
                fee_shares = asset_config.fee_shares;
            }
            let fee_amount = calculate_collateral(fee_shares, asset_config, true);

            // Deduct the fee shares and amount from the total collateral shares and reserve
            asset_config.fee_shares -= fee_shares;
            asset_config.total_collateral_shares -= fee_shares;
            asset_config.reserve -= fee_amount;

            // Write the updated asset config back to storage
            self.asset_configs.write(asset, asset_config);

            // Convert shares to amount (round down)
            let fee_recipient = self.fee_recipient.read();

            assert!(
                IERC20Dispatcher { contract_address: asset }.transfer(fee_recipient, fee_amount), "fee-transfer-failed",
            );

            self.emit(ClaimFees { asset, recipient: fee_recipient, fee_shares, fee_amount });
        }

        /// Returns the number of unclaimed fee shares and the corresponding amount
        fn get_fees(self: @ContractState, asset: ContractAddress) -> (u256, u256) {
            let asset_config = self.asset_config(asset);
            let fee_shares = asset_config.fee_shares;

            // Convert shares to amount (round down)
            let amount = calculate_collateral(fee_shares, asset_config, true);

            (fee_shares, amount)
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
            // update rate accumulator before updating the interest rate parameter
            let asset_config = self.asset_config(asset);
            self.asset_configs.write(asset, asset_config);
            self.interest_rate_model.set_interest_rate_parameter(asset, parameter, value);
        }

        /// Returns the interest rate configuration for a given asset
        /// # Arguments
        /// * `asset` - address of the asset
        /// # Returns
        /// * `interest_rate_config` - interest rate configuration
        fn interest_rate_config(self: @ContractState, asset: ContractAddress) -> InterestRateConfig {
            self.interest_rate_model.interest_rate_configs.read(asset)
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

        /// Sets the configuration for a given pair
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `pair_config` - pair configuration
        fn set_pair_config(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            pair_config: PairConfig,
        ) {
            self.assert_not_paused();
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            assert!(collateral_asset != debt_asset, "identical-assets");
            assert_pair_config(pair_config);
            assert_storable_pair_config(pair_config);

            // assert asset_configs exist
            assert_asset_config_exists(self.asset_config(collateral_asset));
            assert_asset_config_exists(self.asset_config(debt_asset));

            self.pair_configs.write((collateral_asset, debt_asset), pair_config);
            self.emit(SetPairConfig { collateral_asset, debt_asset, pair_config });
        }

        /// Sets a parameter for a given pair configuration
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_pair_parameter(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            parameter: felt252,
            value: u128,
        ) {
            self.assert_not_paused();
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            assert!(collateral_asset != debt_asset, "identical-assets");
            let mut pair_config = self.pair_configs.read((collateral_asset, debt_asset));
            if parameter == 'max_ltv' {
                pair_config.max_ltv = value.try_into().unwrap();
            } else if parameter == 'liquidation_factor' {
                pair_config
                    .liquidation_factor =
                        if value == 0 {
                            SCALE.try_into().unwrap()
                        } else {
                            value.try_into().unwrap()
                        };
            } else if parameter == 'debt_cap' {
                pair_config.debt_cap = value;
            } else {
                panic!("invalid-pair-parameter");
            }
            assert_pair_config(pair_config);
            assert_storable_pair_config(pair_config);
            self.pair_configs.write((collateral_asset, debt_asset), pair_config);
            self.emit(SetPairConfig { collateral_asset, debt_asset, pair_config });
        }

        /// Returns the configuration for a given pair
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `pair_config` - pair configuration
        fn pair_config(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> PairConfig {
            self.pair_configs.read((collateral_asset, debt_asset))
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

        /// Sets the pausing agent
        /// # Arguments
        /// * `pausing_agent` - address of the pausing agent
        fn set_pausing_agent(ref self: ContractState, pausing_agent: ContractAddress) {
            self.assert_not_paused();
            assert!(get_caller_address() == self.curator.read(), "caller-not-curator");
            self.pausing_agent.write(pausing_agent);
            self.emit(SetPausingAgent { agent: pausing_agent });
        }

        /// Returns the address of the pausing agent
        /// # Returns
        /// * `pausing_agent` - address of the pausing agent
        fn pausing_agent(self: @ContractState) -> ContractAddress {
            self.pausing_agent.read()
        }

        /// Pauses the contract
        /// Requirements: The contract is not paused
        /// Emits a `Paused` event
        fn pause(ref self: ContractState) {
            assert!(
                get_caller_address() == self.ownable.owner()
                    || get_caller_address() == self.curator.read()
                    || get_caller_address() == self.pausing_agent.read(),
                "caller-not-authorized",
            );
            assert!(!self.paused.read(), "contract-already-paused");
            self.paused.write(true);
            self.emit(ContractPaused { account: get_caller_address() });
        }

        /// Lifts the pause on the contract
        /// Requirements: The contract is paused
        /// Emits an `Unpaused` event
        fn unpause(ref self: ContractState) {
            assert!(
                get_caller_address() == self.ownable.owner() || get_caller_address() == self.curator.read(),
                "caller-not-authorized",
            );
            assert!(self.paused.read(), "contract-already-unpaused");
            self.paused.write(false);
            self.emit(ContractUnpaused { account: get_caller_address() });
        }

        /// Returns true if the contract is paused, and false otherwise
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
