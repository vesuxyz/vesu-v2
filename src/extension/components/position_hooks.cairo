use starknet::storage_access::StorePacking;
use vesu::packing::{SHIFT_128, into_u123, split_128};
use vesu::units::SCALE;

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct ShutdownConfig {
    pub recovery_period: u64, // [seconds]
    pub subscription_period: u64 // [seconds]
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct LiquidationConfig {
    pub liquidation_factor: u64 // [SCALE]
}

pub fn assert_liquidation_config(liquidation_config: LiquidationConfig) {
    assert!(liquidation_config.liquidation_factor.into() <= SCALE, "invalid-liquidation-config");
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct Pair {
    pub total_collateral_shares: u256, // packed as u128 [SCALE] 
    pub total_nominal_debt: u256 // packed as u123 [SCALE]
}

#[derive(PartialEq, Copy, Drop, Serde, Default, starknet::Store)]
pub enum ShutdownMode {
    #[default]
    None,
    Recovery,
    Subscription,
    Redemption,
}

#[derive(PartialEq, Copy, Drop, Serde)]
pub struct ShutdownStatus {
    pub shutdown_mode: ShutdownMode,
    pub violating: bool,
}

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct ShutdownState {
    // current set shutdown mode (overwrites the inferred shutdown mode)
    pub shutdown_mode: ShutdownMode,
    // timestamp at which the shutdown mode was last updated
    pub last_updated: u64,
}

impl PairPacking of StorePacking<Pair, felt252> {
    fn pack(value: Pair) -> felt252 {
        let total_collateral_shares: u128 = value
            .total_collateral_shares
            .try_into()
            .expect('pack-total_collateral-shares');
        let total_nominal_debt: u128 = value.total_nominal_debt.try_into().expect('pack-total_nominal-debt');
        let total_nominal_debt = into_u123(total_nominal_debt, 'pack-total_nominal-debt-u123');
        total_collateral_shares.into() + total_nominal_debt * SHIFT_128
    }

    fn unpack(value: felt252) -> Pair {
        let (total_nominal_debt, total_collateral_shares) = split_128(value.into());
        Pair { total_collateral_shares: total_collateral_shares.into(), total_nominal_debt: total_nominal_debt.into() }
    }
}

#[starknet::component]
pub mod position_hooks_component {
    use alexandria_math::i257::{I257Trait, i257};
    use core::num::traits::Zero;
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use vesu::common::{calculate_collateral_and_debt_value, calculate_debt};
    use vesu::data_model::Context;
    use vesu::extension::components::position_hooks::{
        LiquidationConfig, Pair, ShutdownConfig, ShutdownMode, ShutdownState, ShutdownStatus, assert_liquidation_config,
    };
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::units::SCALE;

    #[storage]
    pub struct Storage {
        // contains the shutdown configuration
        pub shutdown_config: ShutdownConfig,
        // contains the current shutdown mode
        pub fixed_shutdown_mode: ShutdownState,
        // contains the liquidation configuration for each pair
        // (collateral_asset, debt_asset) -> liquidation configuration
        pub liquidation_configs: Map<(ContractAddress, ContractAddress), LiquidationConfig>,
        // tracks the total collateral shares and the total nominal debt for each pair
        // (collateral asset, debt asset) -> pair configuration
        pub pairs: Map<(ContractAddress, ContractAddress), Pair>,
        // tracks the debt caps for each asset
        pub debt_caps: Map<(ContractAddress, ContractAddress), u256>,
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

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        SetLiquidationConfig: SetLiquidationConfig,
        SetShutdownConfig: SetShutdownConfig,
        SetShutdownMode: SetShutdownMode,
        SetDebtCap: SetDebtCap,
    }

    #[generate_trait]
    pub impl PositionHooksTrait<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>,
    > of Trait<TContractState> {
        /// Sets the debt cap for an asset.
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `debt_cap` - debt cap
        fn set_debt_cap(
            ref self: ComponentState<TContractState>,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            debt_cap: u256,
        ) {
            self.debt_caps.write((collateral_asset, debt_asset), debt_cap);
            self.emit(SetDebtCap { collateral_asset, debt_asset, debt_cap });
        }

        /// Sets the liquidation configuration for an asset pairing.
        /// # Arguments
        /// * `collateral_asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        /// * `liquidation_config` - liquidation configuration
        fn set_liquidation_config(
            ref self: ComponentState<TContractState>,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            liquidation_config: LiquidationConfig,
        ) {
            assert_liquidation_config(liquidation_config);

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

        /// Sets the shutdown configuration.
        /// # Arguments
        /// * `shutdown_config` - shutdown configuration
        fn set_shutdown_config(ref self: ComponentState<TContractState>, shutdown_config: ShutdownConfig) {
            self.shutdown_config.write(shutdown_config);

            self.emit(SetShutdownConfig { shutdown_config });
        }

        /// Note: In order to get the shutdown status for the entire pool, this function needs to be called on all
        /// pairs associated with the pool.
        /// The furthest progressed shutdown mode for a pair is the shutdown mode of the pool.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// # Returns
        /// * `shutdown_status` - shutdown status of the pool
        fn shutdown_status(self: @ComponentState<TContractState>, context: Context) -> ShutdownStatus {
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

        /// Transitions into recovery mode if a pair is violating the constraints
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// # Returns
        /// * `shutdown_mode` - the shutdown mode
        fn update_shutdown_status(ref self: ComponentState<TContractState>, context: Context) -> ShutdownMode {
            let Context { collateral_asset, collateral_asset_config, .. } = context;

            // check if the shutdown mode has been overwritten
            let ShutdownState { shutdown_mode, .. } = self.fixed_shutdown_mode.read();

            if shutdown_mode == ShutdownMode::Redemption {
                // set max_utilization to 100% if it's not already set
                if collateral_asset_config.max_utilization != SCALE {
                    ISingletonV2Dispatcher { contract_address: starknet::get_contract_address() }
                        .set_asset_parameter(collateral_asset, 'max_utilization', SCALE);
                }
            }

            // check if the shutdown mode has been set to a non-none value
            if shutdown_mode != ShutdownMode::None {
                return shutdown_mode;
            }

            let ShutdownStatus { shutdown_mode, violating } = self.shutdown_status(context);

            // if there is a current violation and no timestamp exists for the pair, then set the it (recovery)
            if violating {
                self.fixed_shutdown_mode.write(ShutdownState { shutdown_mode, last_updated: get_block_timestamp() });
            }

            shutdown_mode
        }

        /// Sets the shutdown mode which overwrites the inferred shutdown mode.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `shutdown_mode` - shutdown mode
        fn set_shutdown_mode(ref self: ComponentState<TContractState>, new_shutdown_mode: ShutdownMode) {
            let ShutdownState { shutdown_mode, last_updated, .. } = self.fixed_shutdown_mode.read();

            // can only transition to recovery mode if the shutdown mode is in normal mode
            assert!(
                shutdown_mode != ShutdownMode::None || new_shutdown_mode == ShutdownMode::Recovery,
                "shutdown-mode-not-none",
            );
            // can only transition back to normal mode or subscription mode if the shutdown mode is in recovery mode
            assert!(
                shutdown_mode != ShutdownMode::Recovery
                    || (new_shutdown_mode == ShutdownMode::None || new_shutdown_mode == ShutdownMode::Subscription),
                "shutdown-mode-not-recovery",
            );
            // can only transition to redemption mode if the shutdown mode is in subscription mode
            assert!(
                shutdown_mode != ShutdownMode::Subscription || new_shutdown_mode == ShutdownMode::Redemption,
                "shutdown-mode-not-subscription",
            );
            // can not transition into any shutdown mode if the shutdown mode is in redemption mode
            assert!(shutdown_mode != ShutdownMode::Redemption, "shutdown-mode-in-redemption");

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

            self.emit(SetShutdownMode { shutdown_mode, last_updated: shutdown_state.last_updated });
        }

        /// Updates the tracked total collateral shares and the total nominal debt assigned to a specific pair.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral_shares_delta` - collateral shares balance delta of the position
        /// * `nominal_debt_delta` - nominal debt balance delta of the position
        fn update_pair(
            ref self: ComponentState<TContractState>,
            context: Context,
            collateral_shares_delta: i257,
            nominal_debt_delta: i257,
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

        /// Implements position accounting based on the current shutdown mode.
        /// Each shutdown mode has different constraints on the collateral and debt amounts:
        /// - Normal Mode: collateral and debt amounts are allowed to be modified in any way
        /// - Recovery Mode: collateral can only be added, debt can only be repaid
        /// - Subscription Mode: collateral balance can not be modified, debt can only be repaid
        /// - Redemption Mode: collateral can only be withdrawn, debt balance can not be modified
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral_delta` - collateral balance delta of the position
        /// * `collateral_shares_delta` - collateral shares balance delta of the position
        /// * `debt_delta` - debt balance delta of the position
        /// * `nominal_debt_delta` - nominal debt balance delta of the position
        fn after_modify_position(
            ref self: ComponentState<TContractState>,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
        ) {
            self.update_pair(context, collateral_shares_delta, nominal_debt_delta);

            let shutdown_mode = self.update_shutdown_status(context);

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
        fn before_liquidate_position(
            ref self: ComponentState<TContractState>,
            context: Context,
            min_collateral_to_receive: u256,
            mut debt_to_repay: u256,
        ) -> (u256, u256, u256) {
            // don't allow for liquidations if the pool is not in normal or recovery mode
            let shutdown_mode = self.update_shutdown_status(context);
            assert!(
                (shutdown_mode == ShutdownMode::None || shutdown_mode == ShutdownMode::Recovery)
                    && context.collateral_asset_price.is_valid
                    && context.debt_asset_price.is_valid,
                "emergency-mode",
            );

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

        /// Implements logic to execute after a position gets liquidated.
        /// # Arguments
        /// * `context` - contextual state of the user (position owner)
        /// * `collateral_shares_delta` - collateral shares balance delta of the position
        /// * `nominal_debt_delta` - nominal debt balance delta of the position
        fn after_liquidate_position(
            ref self: ComponentState<TContractState>,
            context: Context,
            collateral_shares_delta: i257,
            nominal_debt_delta: i257,
        ) {
            self.update_pair(context, collateral_shares_delta, nominal_debt_delta);
            self.update_shutdown_status(context);
        }
    }
}
