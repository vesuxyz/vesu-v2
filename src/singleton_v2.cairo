use alexandria_math::i257::i257;
use starknet::{ClassHash, ContractAddress};
use vesu::data_model::{
    Amount, AssetConfig, AssetParams, Context, LTVConfig, LTVParams, LiquidatePositionParams, ModifyPositionParams,
    Position, UpdatePositionResponse,
};

#[starknet::interface]
pub trait IFlashLoanReceiver<TContractState> {
    fn on_flash_loan(
        ref self: TContractState, sender: ContractAddress, asset: ContractAddress, amount: u256, data: Span<felt252>,
    );
}

#[starknet::interface]
pub trait ISingletonV2<TContractState> {
    fn creator_nonce(self: @TContractState, creator: ContractAddress) -> felt252;
    fn extension(self: @TContractState, pool_id: felt252) -> ContractAddress;
    fn whitelisted_extension(self: @TContractState, extension: ContractAddress) -> bool;
    fn asset_config(self: @TContractState, pool_id: felt252, asset: ContractAddress) -> (AssetConfig, u256);
    fn ltv_config(
        self: @TContractState, pool_id: felt252, collateral_asset: ContractAddress, debt_asset: ContractAddress,
    ) -> LTVConfig;
    fn position(
        self: @TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    ) -> (Position, u256, u256);
    fn check_collateralization(
        self: @TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    ) -> (bool, u256, u256);
    fn rate_accumulator(self: @TContractState, pool_id: felt252, asset: ContractAddress) -> u256;
    fn utilization(self: @TContractState, pool_id: felt252, asset: ContractAddress) -> u256;
    fn delegation(
        self: @TContractState, pool_id: felt252, delegator: ContractAddress, delegatee: ContractAddress,
    ) -> bool;
    fn calculate_pool_id(self: @TContractState, caller_address: ContractAddress, nonce: felt252) -> felt252;
    fn calculate_debt(self: @TContractState, nominal_debt: i257, rate_accumulator: u256, asset_scale: u256) -> u256;
    fn calculate_nominal_debt(self: @TContractState, debt: i257, rate_accumulator: u256, asset_scale: u256) -> u256;
    fn calculate_collateral_shares(
        self: @TContractState, pool_id: felt252, asset: ContractAddress, collateral: i257,
    ) -> u256;
    fn calculate_collateral(
        self: @TContractState, pool_id: felt252, asset: ContractAddress, collateral_shares: i257,
    ) -> u256;
    fn deconstruct_collateral_amount(
        self: @TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        collateral: Amount,
    ) -> (i257, i257);
    fn deconstruct_debt_amount(
        self: @TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        debt: Amount,
    ) -> (i257, i257);
    fn context(
        self: @TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    ) -> Context;
    fn create_pool(
        ref self: TContractState,
        asset_params: Span<AssetParams>,
        ltv_params: Span<LTVParams>,
        extension: ContractAddress,
    ) -> felt252;
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
    fn modify_delegation(ref self: TContractState, pool_id: felt252, delegatee: ContractAddress, delegation: bool);
    fn donate_to_reserve(ref self: TContractState, pool_id: felt252, asset: ContractAddress, amount: u256);
    fn set_asset_config(ref self: TContractState, pool_id: felt252, params: AssetParams);
    fn set_ltv_config(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        ltv_config: LTVConfig,
    );
    fn set_asset_parameter(
        ref self: TContractState, pool_id: felt252, asset: ContractAddress, parameter: felt252, value: u256,
    );
    fn set_extension(ref self: TContractState, pool_id: felt252, extension: ContractAddress);
    fn set_extension_whitelist(ref self: TContractState, extension: ContractAddress, approved: bool);
    fn claim_fee_shares(ref self: TContractState, pool_id: felt252, asset: ContractAddress);

    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(ref self: TContractState, new_implementation: ClassHash);
}

#[starknet::contract]
mod SingletonV2 {
    use alexandria_math::i257::{I257Trait, i257};
    use core::num::traits::Zero;
    use core::poseidon;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ClassHash, ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use vesu::common::{
        apply_position_update_to_context, calculate_collateral, calculate_collateral_and_debt_value,
        calculate_collateral_shares, calculate_debt, calculate_fee_shares, calculate_nominal_debt,
        calculate_utilization, deconstruct_collateral_amount, deconstruct_debt_amount, is_collateralized,
    };
    use vesu::data_model::{
        Amount, AmountDenomination, AssetConfig, AssetParams, AssetPrice, Context, LTVConfig, LTVParams,
        LiquidatePositionParams, ModifyPositionParams, Position, UpdatePositionResponse, assert_asset_config,
        assert_asset_config_exists, assert_ltv_config,
    };
    use vesu::extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use vesu::math::pow_10;
    use vesu::packing::{AssetConfigPacking, PositionPacking, assert_storable_asset_config};
    use vesu::singleton_v2::{
        IFlashLoanReceiverDispatcher, IFlashLoanReceiverDispatcherTrait, ISingletonV2, ISingletonV2Dispatcher,
        ISingletonV2DispatcherTrait,
    };
    use vesu::units::INFLATION_FEE_SHARES;

    #[storage]
    struct Storage {
        // tracks a nonce for each creator of a pool to deterministically derive the pool_id from it
        // creator -> nonce
        creator_nonce: Map<ContractAddress, felt252>,
        // tracks the address of the extension contract for each pool
        // pool_id -> extension
        extensions: Map<felt252, ContractAddress>,
        // tracks the configuration / state of each asset in each pool
        // (pool_id, asset) -> asset configuration
        asset_configs: Map<(felt252, ContractAddress), AssetConfig>,
        // tracks the max. allowed loan-to-value ratio for each asset pairing in each pool
        // (pool_id, collateral_asset, debt_asset) -> ltv configuration
        ltv_configs: Map<(felt252, ContractAddress, ContractAddress), LTVConfig>,
        // tracks the state of each position in each pool
        // (pool_id, collateral_asset, debt_asset, user) -> position
        positions: Map<(felt252, ContractAddress, ContractAddress, ContractAddress), Position>,
        // tracks the delegation status for each delegator to a delegatee for a specific pool
        // (pool_id, delegator, delegatee) -> delegation
        delegations: Map<(felt252, ContractAddress, ContractAddress), bool>,
        // tracks the whitelisted extensions
        whitelisted_extensions: Map<ContractAddress, bool>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[derive(Drop, starknet::Event)]
    struct CreatePool {
        #[key]
        pool_id: felt252,
        #[key]
        extension: ContractAddress,
        #[key]
        creator: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ModifyPosition {
        #[key]
        pool_id: felt252,
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
        pool_id: felt252,
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
    struct AccrueFees {
        #[key]
        pool_id: felt252,
        #[key]
        asset: ContractAddress,
        #[key]
        recipient: ContractAddress,
        fee_shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct UpdateContext {
        #[key]
        pool_id: felt252,
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
        pool_id: felt252,
        #[key]
        delegator: ContractAddress,
        #[key]
        delegatee: ContractAddress,
        delegation: bool,
    }

    #[derive(Drop, starknet::Event)]
    struct Donate {
        #[key]
        pool_id: felt252,
        #[key]
        asset: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct SetLTVConfig {
        #[key]
        pool_id: felt252,
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        ltv_config: LTVConfig,
    }

    #[derive(Drop, starknet::Event)]
    struct SetAssetConfig {
        #[key]
        pool_id: felt252,
        #[key]
        asset: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SetAssetParameter {
        #[key]
        pool_id: felt252,
        #[key]
        asset: ContractAddress,
        #[key]
        parameter: felt252,
        value: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct SetExtension {
        #[key]
        pool_id: felt252,
        #[key]
        extension: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SetExtensionWhitelist {
        #[key]
        extension: ContractAddress,
        whitelisted: bool,
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
        CreatePool: CreatePool,
        ModifyPosition: ModifyPosition,
        LiquidatePosition: LiquidatePosition,
        AccrueFees: AccrueFees,
        UpdateContext: UpdateContext,
        Flashloan: Flashloan,
        ModifyDelegation: ModifyDelegation,
        Donate: Donate,
        SetLTVConfig: SetLTVConfig,
        SetAssetConfig: SetAssetConfig,
        SetAssetParameter: SetAssetParameter,
        SetExtension: SetExtension,
        SetExtensionWhitelist: SetExtensionWhitelist,
        ContractUpgraded: ContractUpgraded,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    /// Computes the new rate accumulator and the interest rate at full utilization for a given asset in a pool
    /// # Arguments
    /// * `pool_id` - id of the pool
    /// * `extension` - address of the pool's extension contract
    /// * `asset` - address of the asset
    /// # Returns
    /// * `asset_config` - asset config containing the updated last rate accumulator and full utilization rate
    fn rate_accumulator(
        pool_id: felt252, extension: ContractAddress, asset: ContractAddress, mut asset_config: AssetConfig,
    ) -> AssetConfig {
        let AssetConfig { total_nominal_debt, scale, .. } = asset_config;
        let AssetConfig { last_rate_accumulator, last_full_utilization_rate, last_updated, .. } = asset_config;
        let total_debt = calculate_debt(total_nominal_debt, last_rate_accumulator, scale, false);
        // calculate utilization based on previous rate accumulator
        let utilization = calculate_utilization(asset_config.reserve, total_debt);
        // calculate the new rate accumulator
        let (rate_accumulator, full_utilization_rate) = IExtensionDispatcher { contract_address: extension }
            .rate_accumulator(
                pool_id, asset, utilization, last_updated, last_rate_accumulator, last_full_utilization_rate,
            );

        asset_config.last_rate_accumulator = rate_accumulator;
        asset_config.last_full_utilization_rate = full_utilization_rate;
        asset_config.last_updated = get_block_timestamp();

        asset_config
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
        /// Asserts that the delegatee has the delegate of the delegator for a specific pool
        fn assert_ownership(
            ref self: ContractState, pool_id: felt252, extension: ContractAddress, delegator: ContractAddress,
        ) {
            let has_delegation = self.delegations.read((pool_id, delegator, get_caller_address()));
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
                self.assert_ownership(context.pool_id, context.extension, context.user);
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
        fn _set_extension(ref self: ContractState, pool_id: felt252, extension: ContractAddress) {
            assert!(extension.is_non_zero(), "extension-is-zero");
            assert!(self.whitelisted_extensions.read(extension), "extension-not-whitelisted");

            self.extensions.write(pool_id, extension);

            self.emit(SetExtension { pool_id, extension });
        }

        /// Settles all intermediate outstanding collateral and debt deltas for a position / user
        fn settle_position(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            collateral_delta: i257,
            debt_asset: ContractAddress,
            debt_delta: i257,
            bad_debt: u256,
        ) {
            let (contract, caller) = (get_contract_address(), get_caller_address());

            if collateral_delta < Zero::zero() {
                let (asset_config, _) = self.asset_config(pool_id, collateral_asset);
                transfer_asset(collateral_asset, contract, caller, collateral_delta.abs(), asset_config.is_legacy);
            } else if collateral_delta > Zero::zero() {
                let (asset_config, _) = self.asset_config(pool_id, collateral_asset);
                transfer_asset(collateral_asset, caller, contract, collateral_delta.abs(), asset_config.is_legacy);
            }

            if debt_delta < Zero::zero() {
                let (asset_config, _) = self.asset_config(pool_id, debt_asset);
                transfer_asset(debt_asset, caller, contract, debt_delta.abs() - bad_debt, asset_config.is_legacy);
            } else if debt_delta > Zero::zero() {
                let (asset_config, _) = self.asset_config(pool_id, debt_asset);
                transfer_asset(debt_asset, contract, caller, debt_delta.abs(), asset_config.is_legacy);
            }
        }

        /// Increases the extension's collateral shares balance by the fee share amount
        fn attribute_fee_shares(
            ref self: ContractState,
            pool_id: felt252,
            extension: ContractAddress,
            asset: ContractAddress,
            fee_shares: u256,
        ) {
            if fee_shares == 0 {
                return;
            }
            let mut position = self.positions.read((pool_id, asset, Zero::zero(), extension));
            position.collateral_shares += fee_shares;
            self.positions.write((pool_id, asset, Zero::zero(), extension), position);
            self.emit(AccrueFees { pool_id, asset, recipient: extension, fee_shares });
        }

        /// Updates the state of a position and the corresponding collateral and debt asset
        fn update_position(
            ref self: ContractState, ref context: Context, collateral: Amount, debt: Amount, bad_debt: u256,
        ) -> UpdatePositionResponse {
            let initial_total_collateral_shares = context.collateral_asset_config.total_collateral_shares;

            // apply the position modification to the context
            let (collateral_delta, mut collateral_shares_delta, debt_delta, nominal_debt_delta) =
                apply_position_update_to_context(
                ref context, collateral, debt, bad_debt,
            );

            let Context { pool_id, collateral_asset, debt_asset, user, .. } = context;

            // charge the inflation fee for the first depositor for that asset in the pool
            let inflation_fee = if initial_total_collateral_shares == 0 && !collateral_shares_delta.is_negative() {
                assert!(user != Zero::zero(), "zero-user-not-allowed");
                self
                    .positions
                    .write(
                        (pool_id, collateral_asset, debt_asset, Zero::zero()),
                        Position { collateral_shares: INFLATION_FEE_SHARES, nominal_debt: 0 },
                    );
                assert!(
                    context.position.collateral_shares >= INFLATION_FEE_SHARES,
                    "inflation-fee-gt-collateral-shares-delta",
                );
                context.position.collateral_shares -= INFLATION_FEE_SHARES;
                INFLATION_FEE_SHARES
            } else {
                0
            };

            // store updated context
            self.positions.write((pool_id, collateral_asset, debt_asset, user), context.position);
            self.asset_configs.write((pool_id, collateral_asset), context.collateral_asset_config);
            self.asset_configs.write((pool_id, debt_asset), context.debt_asset_config);

            self
                .emit(
                    UpdateContext {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        collateral_asset_config: context.collateral_asset_config,
                        debt_asset_config: context.debt_asset_config,
                        collateral_asset_price: context.collateral_asset_price,
                        debt_asset_price: context.debt_asset_price,
                    },
                );

            // mint fee shares to the recipient
            self
                .attribute_fee_shares(
                    pool_id, context.extension, collateral_asset, context.collateral_asset_fee_shares,
                );
            self.attribute_fee_shares(pool_id, context.extension, debt_asset, context.debt_asset_fee_shares);

            // verify invariants:
            self.assert_delta_invariants(collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta);
            self.assert_floor_invariant(context);

            // deduct inflation fee from the collateral shares delta
            collateral_shares_delta =
                I257Trait::new(collateral_shares_delta.abs() - inflation_fee, collateral_shares_delta.is_negative());

            UpdatePositionResponse {
                collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, bad_debt,
            }
        }
    }

    #[abi(embed_v0)]
    impl SingletonV2Impl of ISingletonV2<ContractState> {
        /// Returns the nonce of the creator of the previously created pool
        /// # Arguments
        /// * `creator` - address of the pool creator
        /// # Returns
        /// * `nonce` - nonce of the creator
        fn creator_nonce(self: @ContractState, creator: ContractAddress) -> felt252 {
            self.creator_nonce.read(creator)
        }

        /// Returns the pool's extension address
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// # Returns
        /// * `extension` - address of the extension contract
        fn extension(self: @ContractState, pool_id: felt252) -> ContractAddress {
            self.extensions.read(pool_id)
        }

        /// Returns whether an extension is whitelisted
        /// # Arguments
        /// * `extension` - address of the extension contract
        /// # Returns
        /// * `whitelisted` - whether the extension is whitelisted
        fn whitelisted_extension(self: @ContractState, extension: ContractAddress) -> bool {
            self.whitelisted_extensions.read(extension)
        }

        /// Returns the configuration / state of an asset for a given pool
        /// This method does not prevent reentrancy which may result in asset_config being out of date.
        /// For contract to contract interactions asset_config() should be used instead.
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        /// # Returns
        /// * `asset_config` - asset configuration
        /// * `fee_shares` - accrued fee shares minted to the fee recipient
        fn asset_config(self: @ContractState, pool_id: felt252, asset: ContractAddress) -> (AssetConfig, u256) {
            let extension = self.extensions.read(pool_id);
            assert!(extension.is_non_zero(), "unknown-pool");

            let mut asset_config = self.asset_configs.read((pool_id, asset));
            let mut fee_shares = 0;

            if asset_config.last_updated != get_block_timestamp() && asset != Zero::zero() {
                let new_asset_config = rate_accumulator(pool_id, extension, asset, asset_config);
                fee_shares = calculate_fee_shares(asset_config, new_asset_config.last_rate_accumulator);
                asset_config = new_asset_config;
                asset_config.total_collateral_shares += fee_shares;
            }

            (asset_config, fee_shares)
        }

        /// Returns the loan-to-value configuration between two assets (pair) in the pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// # Returns
        /// * `ltv_config` - ltv configuration
        fn ltv_config(
            self: @ContractState, pool_id: felt252, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> LTVConfig {
            self.ltv_configs.read((pool_id, collateral_asset, debt_asset))
        }

        /// Returns the current state of a position
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// # Returns
        /// * `position` - position state
        /// * `collateral` - amount of collateral (computed from position.collateral_shares) [asset scale]
        /// * `debt` - amount of debt (computed from position.nominal_debt) [asset scale]
        fn position(
            self: @ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
        ) -> (Position, u256, u256) {
            let context = self.context(pool_id, collateral_asset, debt_asset, user);
            let (collateral, _, debt, _) = calculate_collateral_and_debt_value(context, context.position);
            (context.position, collateral, debt)
        }

        /// Checks if a position is collateralized according to the max. loan-to-value ratio
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// # Returns
        /// * `collateralized` - true if the position is collateralized, false otherwise
        /// * `collateral_value` - USD value of the collateral [SCALE]
        /// * `debt_value` - USD value of the debt [SCALE]
        fn check_collateralization(
            self: @ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
        ) -> (bool, u256, u256) {
            let context = self.context(pool_id, collateral_asset, debt_asset, user);
            let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(context, context.position);
            (is_collateralized(collateral_value, debt_value, context.max_ltv.into()), collateral_value, debt_value)
        }

        /// Calculates the current (using the current block's timestamp) rate accumulator for a given asset in a pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        /// # Returns
        /// * `rate_accumulator` - computed rate accumulator [SCALE]
        fn rate_accumulator(self: @ContractState, pool_id: felt252, asset: ContractAddress) -> u256 {
            let (asset_config, _) = self.asset_config(pool_id, asset);
            asset_config.last_rate_accumulator
        }

        /// Calculates the current utilization of an asset in a pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        /// # Returns
        /// * `utilization` - computed utilization [SCALE]
        fn utilization(self: @ContractState, pool_id: felt252, asset: ContractAddress) -> u256 {
            let (asset_config, _) = self.asset_config(pool_id, asset);
            utilization(asset_config)
        }

        /// Returns the delegation status of a delegator to a delegatee for a specific pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `delegator` - address of the delegator
        /// * `delegatee` - address of the delegatee
        /// # Returns
        /// * `delegation` - delegation status (true = delegate, false = undelegate)
        fn delegation(
            self: @ContractState, pool_id: felt252, delegator: ContractAddress, delegatee: ContractAddress,
        ) -> bool {
            self.delegations.read((pool_id, delegator, delegatee))
        }

        /// Derives the pool_id for a given creator and nonce
        /// # Arguments
        /// * `caller_address` - address of the creator
        /// * `nonce` - nonce of the creator (creator_nonce() + 1 to derive the pool_id of the next pool)
        /// # Returns
        /// * `pool_id` - id of the pool
        fn calculate_pool_id(self: @ContractState, caller_address: ContractAddress, nonce: felt252) -> felt252 {
            let mut data: Array<felt252> = ArrayTrait::new();
            data.append('v2'.into());
            data.append(caller_address.into());
            data.append(nonce);
            poseidon::poseidon_hash_span(data.span())
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
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        /// * `collateral` - amount of collateral [asset scale]
        /// # Returns
        /// * `collateral_shares` - computed collateral shares [SCALE]
        fn calculate_collateral_shares(
            self: @ContractState, pool_id: felt252, asset: ContractAddress, collateral: i257,
        ) -> u256 {
            let (asset_config, _) = self.asset_config(pool_id, asset);
            calculate_collateral_shares(collateral.abs(), asset_config, collateral.is_negative())
        }

        /// Calculates the amount of collateral assets (that can e.g. be redeemed)  for a given amount of collateral
        /// shares # Arguments
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        /// * `collateral_shares` - amount of collateral shares
        /// # Returns
        /// * `collateral` - computed collateral [asset scale]
        fn calculate_collateral(
            self: @ContractState, pool_id: felt252, asset: ContractAddress, collateral_shares: i257,
        ) -> u256 {
            let (asset_config, _) = self.asset_config(pool_id, asset);
            calculate_collateral(collateral_shares.abs(), asset_config, !collateral_shares.is_negative())
        }

        /// Deconstructs the collateral amount into collateral delta, collateral shares delta and it's sign
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// * `collateral` - amount of collateral
        /// # Returns
        /// * `collateral_delta` - computed collateral delta [asset scale]
        /// * `collateral_shares_delta` - computed collateral shares delta [SCALE]
        fn deconstruct_collateral_amount(
            self: @ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
            collateral: Amount,
        ) -> (i257, i257) {
            let context = self.context(pool_id, collateral_asset, debt_asset, user);
            deconstruct_collateral_amount(collateral, context.collateral_asset_config)
        }

        /// Deconstructs the debt amount into debt delta, nominal debt delta and it's sign
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// * `debt` - amount of debt
        /// # Returns
        /// * `debt_delta` - computed debt delta [asset scale]
        /// * `nominal_debt_delta` - computed nominal debt delta [SCALE]
        fn deconstruct_debt_amount(
            self: @ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
            debt: Amount,
        ) -> (i257, i257) {
            let context = self.context(pool_id, collateral_asset, debt_asset, user);
            deconstruct_debt_amount(
                debt, context.debt_asset_config.last_rate_accumulator, context.debt_asset_config.scale,
            )
        }

        /// Loads the contextual state for a given user. This includes the pool's extension address, the state of the
        /// collateral and debt assets, loan-to-value configurations and the state of the position.
        /// This method does not prevent reentrancy which may result in context being out of date.
        /// For contract to contract interactions context() should be used instead.
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `user` - address of the position's owner
        /// # Returns
        /// * `context` - contextual state
        fn context(
            self: @ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
        ) -> Context {
            assert!(collateral_asset != debt_asset, "identical-assets");

            let extension = IExtensionDispatcher { contract_address: self.extensions.read(pool_id) };
            assert!(extension.contract_address.is_non_zero(), "unknown-pool");

            let (collateral_asset_config, collateral_asset_fee_shares) = self.asset_config(pool_id, collateral_asset);
            let (debt_asset_config, debt_asset_fee_shares) = self.asset_config(pool_id, debt_asset);

            Context {
                pool_id,
                extension: extension.contract_address,
                collateral_asset,
                debt_asset,
                collateral_asset_config,
                debt_asset_config,
                collateral_asset_price: if collateral_asset == Zero::zero() {
                    AssetPrice { value: 0, is_valid: true }
                } else {
                    extension.price(pool_id, collateral_asset)
                },
                debt_asset_price: if debt_asset == Zero::zero() {
                    AssetPrice { value: 0, is_valid: true }
                } else {
                    extension.price(pool_id, debt_asset)
                },
                collateral_asset_fee_shares,
                debt_asset_fee_shares,
                max_ltv: self.ltv_configs.read((pool_id, collateral_asset, debt_asset)).max_ltv,
                user,
                position: self.positions.read((pool_id, collateral_asset, debt_asset, user)),
            }
        }

        /// Creates a new pool
        /// # Arguments
        /// * `asset_params` - array of asset parameters
        /// * `ltv_params` - array of loan-to-value parameters
        /// * `extension` - address of the extension contract
        /// # Returns
        /// * `pool_id` - id of the pool
        fn create_pool(
            ref self: ContractState,
            asset_params: Span<AssetParams>,
            mut ltv_params: Span<LTVParams>,
            extension: ContractAddress,
        ) -> felt252 {
            // derive pool id from the address of the creator and the creator's nonce
            let mut nonce = self.creator_nonce.read(get_caller_address());
            nonce += 1;
            self.creator_nonce.write(get_caller_address(), nonce);
            let pool_id = self.calculate_pool_id(get_caller_address(), nonce);

            // link the extension to the pool
            self._set_extension(pool_id, extension);

            // store all asset configurations
            let mut asset_params_copy = asset_params;
            while !asset_params_copy.is_empty() {
                let params = *asset_params_copy.pop_front().unwrap();
                self.set_asset_config(pool_id, params);
            }

            // store all loan-to-value configurations for each asset pair
            while !ltv_params.is_empty() {
                let params = *ltv_params.pop_front().unwrap();
                let collateral_asset = *asset_params.at(params.collateral_asset_index).asset;
                let debt_asset = *asset_params.at(params.debt_asset_index).asset;
                self.set_ltv_config(pool_id, collateral_asset, debt_asset, LTVConfig { max_ltv: params.max_ltv });
            }

            self.emit(CreatePool { pool_id, extension, creator: get_caller_address() });

            pool_id
        }

        /// Adjusts a positions collateral and debt balances
        /// # Arguments
        /// * `params` - see ModifyPositionParams
        /// # Returns
        /// * `response` - see UpdatePositionResponse
        fn modify_position(ref self: ContractState, params: ModifyPositionParams) -> UpdatePositionResponse {
            let ModifyPositionParams { pool_id, collateral_asset, debt_asset, user, collateral, debt, data } = params;

            let context = self.context(pool_id, collateral_asset, debt_asset, user);

            // call before-hook of the extension
            let extension = IExtensionDispatcher { contract_address: context.extension };
            let (collateral, debt) = extension
                .before_modify_position(context, collateral, debt, data, get_caller_address());

            // reload context since the storage might have changed by a reentered call
            let mut context = self.context(pool_id, collateral_asset, debt_asset, user);

            // update the position
            let response = self.update_position(ref context, collateral, debt, 0);
            let UpdatePositionResponse {
                collateral_delta, collateral_shares_delta, debt_delta, nominal_debt_delta, ..,
            } = response;

            // verify invariants
            self.assert_position_invariants(context, collateral_delta, debt_delta);

            // call after-hook of the extension (assets are not settled yet, only the internal state has been updated)
            assert!(
                extension
                    .after_modify_position(
                        context,
                        collateral_delta,
                        collateral_shares_delta,
                        debt_delta,
                        nominal_debt_delta,
                        data,
                        get_caller_address(),
                    ),
                "after-modify-position-failed",
            );

            self
                .emit(
                    ModifyPosition {
                        pool_id,
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
            self
                .settle_position(
                    params.pool_id, params.collateral_asset, collateral_delta, params.debt_asset, debt_delta, 0,
                );

            response
        }

        /// Liquidates a position
        /// # Arguments
        /// * `params` - see LiquidatePositionParams
        /// # Returns
        /// * `response` - see UpdatePositionResponse
        fn liquidate_position(ref self: ContractState, params: LiquidatePositionParams) -> UpdatePositionResponse {
            let LiquidatePositionParams { pool_id, collateral_asset, debt_asset, user, data, .. } = params;

            let context = self.context(pool_id, collateral_asset, debt_asset, user);

            // call before-hook of the extension
            let extension = IExtensionDispatcher { contract_address: context.extension };
            let (collateral, debt, bad_debt) = extension.before_liquidate_position(context, data, get_caller_address());

            // convert unsigned amounts to signed amounts
            let collateral = Amount {
                denomination: AmountDenomination::Assets, value: I257Trait::new(collateral, true),
            };
            let debt = Amount { denomination: AmountDenomination::Assets, value: I257Trait::new(debt, true) };

            // reload context since it might have changed by a reentered call
            let mut context = self.context(pool_id, collateral_asset, debt_asset, user);

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
                        data,
                        get_caller_address(),
                    ),
                "after-liquidate-position-failed",
            );

            self
                .emit(
                    LiquidatePosition {
                        pool_id,
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
            self.settle_position(pool_id, collateral_asset, collateral_delta, debt_asset, debt_delta, bad_debt);

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
            transfer_asset(asset, get_contract_address(), receiver, amount, is_legacy);
            IFlashLoanReceiverDispatcher { contract_address: receiver }
                .on_flash_loan(get_caller_address(), asset, amount, data);
            transfer_asset(asset, receiver, get_contract_address(), amount, is_legacy);

            self.emit(Flashloan { sender: get_caller_address(), receiver, asset, amount });
        }

        /// Modifies the delegation status of a delegator to a delegatee for a specific pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `delegatee` - address of the delegatee
        /// * `delegation` - delegation status (true = delegate, false = undelegate)
        fn modify_delegation(ref self: ContractState, pool_id: felt252, delegatee: ContractAddress, delegation: bool) {
            self.delegations.write((pool_id, get_caller_address(), delegatee), delegation);

            self.emit(ModifyDelegation { pool_id, delegator: get_caller_address(), delegatee, delegation });
        }

        /// Donates an amount of an asset to the pool's reserve
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        /// * `amount` - amount to donate [asset scale]
        fn donate_to_reserve(ref self: ContractState, pool_id: felt252, asset: ContractAddress, amount: u256) {
            let (mut asset_config, fee_shares) = self.asset_config(pool_id, asset);
            assert_asset_config_exists(asset_config);
            // attribute the accrued fee shares to the pool's extension
            self.attribute_fee_shares(pool_id, self.extensions.read(pool_id), asset, fee_shares);
            // donate amount to the reserve
            asset_config.reserve += amount;
            self.asset_configs.write((pool_id, asset), asset_config);
            transfer_asset(asset, get_caller_address(), get_contract_address(), amount, asset_config.is_legacy);

            self.emit(Donate { pool_id, asset, amount });
        }

        /// Sets the loan-to-value configuration between two assets (pair) in the pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `ltv_config` - ltv configuration
        fn set_ltv_config(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            ltv_config: LTVConfig,
        ) {
            assert!(get_caller_address() == self.extensions.read(pool_id), "caller-not-extension");
            assert!(collateral_asset != debt_asset, "identical-assets");
            assert_ltv_config(ltv_config);

            self.ltv_configs.write((pool_id, collateral_asset, debt_asset), ltv_config);

            self.emit(SetLTVConfig { pool_id, collateral_asset, debt_asset, ltv_config });
        }

        /// Sets the configuration / initial state of an asset for a given pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `params` - see AssetParams
        fn set_asset_config(ref self: ContractState, pool_id: felt252, params: AssetParams) {
            assert!(get_caller_address() == self.extensions.read(pool_id), "caller-not-extension");
            assert!(self.asset_configs.read((pool_id, params.asset)).scale == 0, "asset-config-already-exists");

            let asset_config = AssetConfig {
                total_collateral_shares: 0,
                total_nominal_debt: 0,
                reserve: 0,
                max_utilization: params.max_utilization,
                floor: params.floor,
                scale: pow_10(IERC20Dispatcher { contract_address: params.asset }.decimals().into()),
                is_legacy: params.is_legacy,
                last_updated: get_block_timestamp(),
                last_rate_accumulator: params.initial_rate_accumulator,
                last_full_utilization_rate: params.initial_full_utilization_rate,
                fee_rate: params.fee_rate,
            };

            assert_asset_config(asset_config);
            assert_storable_asset_config(asset_config);
            self.asset_configs.write((pool_id, params.asset), asset_config);

            self.emit(SetAssetConfig { pool_id, asset: params.asset });
        }

        /// Sets a parameter of an asset for a given pool
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        /// * `parameter` - parameter name
        /// * `value` - value of the parameter
        fn set_asset_parameter(
            ref self: ContractState, pool_id: felt252, asset: ContractAddress, parameter: felt252, value: u256,
        ) {
            assert!(get_caller_address() == self.extensions.read(pool_id), "caller-not-extension");

            let (mut asset_config, fee_shares) = self.asset_config(pool_id, asset);
            // attribute the accrued fee shares to the pool's extension
            self.attribute_fee_shares(pool_id, self.extensions.read(pool_id), asset, fee_shares);

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
            self.asset_configs.write((pool_id, asset), asset_config);

            self.emit(SetAssetParameter { pool_id, asset, parameter, value });
        }

        /// Sets the pool's extension address.
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `extension` - address of the extension contract
        fn set_extension(ref self: ContractState, pool_id: felt252, extension: ContractAddress) {
            assert!(get_caller_address() == self.extensions.read(pool_id), "caller-not-extension");
            assert!(extension != Zero::zero(), "extension-not-set");
            self._set_extension(pool_id, extension);
        }

        /// Whitelists an extension
        /// # Arguments
        /// * `extension` - address of the extension contract
        /// * `approved` - whether the extension is approved
        fn set_extension_whitelist(ref self: ContractState, extension: ContractAddress, approved: bool) {
            self.ownable.assert_only_owner();
            self.whitelisted_extensions.write(extension, approved);
            self.emit(SetExtensionWhitelist { extension, whitelisted: approved });
        }

        /// Attributes the outstanding fee shares to the pool's extension
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `asset` - address of the asset
        fn claim_fee_shares(ref self: ContractState, pool_id: felt252, asset: ContractAddress) {
            let (asset_config, fee_shares) = self.asset_config(pool_id, asset);
            self.attribute_fee_shares(pool_id, self.extensions.read(pool_id), asset, fee_shares);
            self.asset_configs.write((pool_id, asset), asset_config);
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
}
