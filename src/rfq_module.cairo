use starknet::{ClassHash, ContractAddress};

/// RFQ configuration per collateral/debt asset pair
#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
pub struct RfqConfig {
    pub quote_period: u64, // [seconds] - duration for quote submission
    pub settlement_period: u64, // [seconds] - duration for settlement after quote selection
    pub max_bonus: u64, // [SCALE] - maximum liquidation bonus (e.g., 1.1e18 = 10% bonus)
    pub refreeze_cooldown: u64, // [seconds] - cooldown period after unfreeze before re-freeze allowed
    pub max_quotes: u64, // maximum number of quotes per RFQ to prevent step limit issues
    pub min_debt: u256 // [asset scale] - minimum debt amount required to freeze and process RFQ liquidation
}

/// Position snapshot taken at freeze time
#[derive(PartialEq, Copy, Drop, Serde, starknet::Store, Default)]
pub struct PositionSnapshot {
    pub frozen_at: u64, // [seconds] - timestamp when frozen (0 = not frozen)
    pub rate_accumulator: u256, // [SCALE] - debt rate accumulator at freeze
    pub collateral_price: u256, // [SCALE] - collateral price at freeze
    pub debt_price: u256, // [SCALE] - debt price at freeze
    pub last_unfreeze_at: u64 // [seconds] - timestamp of last unfreeze (for cooldown)
}

#[starknet::interface]
pub trait IRfqModule<TContractState> {
    // Core RFQ functions
    fn create_rfq(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> u64;
    fn submit_quote(ref self: TContractState, rfq_id: u64, collateral_out: u256) -> u64;
    fn select_best_quote(ref self: TContractState, rfq_id: u64) -> u64;
    fn settle_liquidation(ref self: TContractState, rfq_id: u64);

    // Admin functions (curator)
    fn set_whitelisted(ref self: TContractState, liquidator: ContractAddress, allowed: bool);
    fn set_curator(ref self: TContractState, curator: ContractAddress);
    fn set_rfq_config(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, config: RfqConfig,
    );
    fn cancel_rfq(ref self: TContractState, rfq_id: u64);

    // Admin functions (owner)
    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(ref self: TContractState, new_implementation: ClassHash);

    // View functions
    fn get_rfq(self: @TContractState, rfq_id: u64) -> Rfq;
    fn get_active_rfq_id(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> u64;
    fn get_quote(self: @TContractState, quote_id: u64) -> Quote;
    fn get_quotes_for_rfq(self: @TContractState, rfq_id: u64, offset: u64, limit: u64) -> Array<u64>;
    fn is_liquidator_whitelisted(self: @TContractState, liquidator: ContractAddress) -> bool;
    fn rfq_config(self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress) -> RfqConfig;
    fn position_snapshot(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> PositionSnapshot;
    fn curator(self: @TContractState) -> ContractAddress;
    fn pool(self: @TContractState) -> ContractAddress;
}

#[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
pub enum RfqState {
    None,
    Quoting,
    QuoteSelected,
    Settled,
    Expired,
}

#[derive(Copy, Drop, Serde, starknet::Store, Hash)]
pub struct PositionKey {
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Rfq {
    pub rfq_id: u64,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub debt_amount: u256,
    pub collateral_amount: u256,
    pub frozen_at: u64,
    pub collateral_price: u256,
    pub debt_price: u256,
    pub collateral_scale: u256,
    pub debt_scale: u256,
    pub created_at: u64,
    pub quoting_deadline: u64,
    pub settlement_deadline: u64,
    pub state: RfqState,
    pub winner: ContractAddress,
    pub winning_quote_id: u64,
    pub winning_collateral_out: u256,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Quote {
    pub quote_id: u64,
    pub rfq_id: u64,
    pub liquidator: ContractAddress,
    pub collateral_out: u256,
    pub created_at: u64,
}

#[starknet::contract]
mod RfqModule {
    use core::num::traits::{Bounded, Zero};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use vesu::common::{calculate_collateral, calculate_collateral_and_debt_value, calculate_debt, is_collateralized};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::rfq_module::{IRfqModuleDispatcher, IRfqModuleDispatcherTrait};
    use vesu::units::SCALE;
    use super::{IRfqModule, PositionKey, PositionSnapshot, Quote, Rfq, RfqConfig, RfqState};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[storage]
    struct Storage {
        pool: ContractAddress,
        curator: ContractAddress,
        is_whitelisted: Map<ContractAddress, bool>,
        rfq_configs: Map<(ContractAddress, ContractAddress), RfqConfig>,
        position_snapshots: Map<(ContractAddress, ContractAddress, ContractAddress), PositionSnapshot>,
        next_rfq_id: u64,
        next_quote_id: u64,
        rfq_by_id: Map<u64, Rfq>,
        active_rfq_by_position: Map<PositionKey, u64>,
        quote_by_id: Map<u64, Quote>,
        quote_count_by_rfq: Map<u64, u64>,
        quote_ids_by_rfq: Map<(u64, u64), u64>,
        has_quoted: Map<(u64, ContractAddress), bool>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        RfqCreated: RfqCreated,
        QuoteSubmitted: QuoteSubmitted,
        QuoteSelected: QuoteSelected,
        LiquidationSettled: LiquidationSettled,
        QuotingExpired: QuotingExpired,
        SettlementExpired: SettlementExpired,
        RfqConfigSet: RfqConfigSet,
        LiquidatorWhitelisted: LiquidatorWhitelisted,
        CuratorSet: CuratorSet,
        ContractUpgraded: ContractUpgraded,
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct RfqCreated {
        #[key]
        rfq_id: u64,
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        user: ContractAddress,
        debt_amount: u256,
        collateral_amount: u256,
        collateral_price: u256,
        debt_price: u256,
        frozen_at: u64,
        quoting_deadline: u64,
        settlement_deadline: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct QuoteSubmitted {
        #[key]
        rfq_id: u64,
        #[key]
        quote_id: u64,
        #[key]
        liquidator: ContractAddress,
        collateral_out: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct QuoteSelected {
        #[key]
        rfq_id: u64,
        #[key]
        quote_id: u64,
        winner: ContractAddress,
        winning_collateral_out: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct LiquidationSettled {
        #[key]
        rfq_id: u64,
        #[key]
        winner: ContractAddress,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        debt_amount: u256,
        collateral_received: u256,
        bad_debt: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct QuotingExpired {
        #[key]
        rfq_id: u64,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SettlementExpired {
        #[key]
        rfq_id: u64,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
        winner: ContractAddress,
        winning_collateral_out: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct RfqConfigSet {
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        quote_period: u64,
        settlement_period: u64,
        max_bonus: u64,
        refreeze_cooldown: u64,
        max_quotes: u64,
        min_debt: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct LiquidatorWhitelisted {
        #[key]
        liquidator: ContractAddress,
        whitelisted: bool,
    }

    #[derive(Drop, starknet::Event)]
    struct CuratorSet {
        curator: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ContractUpgraded {
        new_implementation: ClassHash,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, curator: ContractAddress, pool: ContractAddress) {
        self.ownable.initializer(owner);
        self.curator.write(curator);
        self.pool.write(pool);
        self.next_rfq_id.write(1);
        self.next_quote_id.write(1);
    }

    #[abi(embed_v0)]
    impl RfqModuleImpl of IRfqModule<ContractState> {
        fn create_rfq(
            ref self: ContractState,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress,
        ) -> u64 {
            let pool = IPoolDispatcher { contract_address: self.pool.read() };

            // Load context from Pool (includes position, asset configs, prices, max_ltv)
            let ctx = pool.context(collateral_asset, debt_asset, user);

            // Verify position is insolvent
            // Note: assumes oracle returns non-zero prices when is_valid is true. A zero collateral_price
            // would pass the insolvency check but cause division-by-zero in submit_quote's max_bonus validation.
            assert(ctx.collateral_asset_price.is_valid, 'invalid-collateral-price');
            assert(ctx.debt_asset_price.is_valid, 'invalid-debt-price');

            let (_, collateral_value, debt, debt_value) = calculate_collateral_and_debt_value(ctx);
            assert(!is_collateralized(collateral_value, debt_value, ctx.max_ltv.into()), 'position-not-insolvent');

            // Load local RFQ config
            let rfq_config = self.rfq_configs.read((collateral_asset, debt_asset));
            assert(rfq_config.quote_period > 0, 'rfq-not-configured');

            // Check position debt meets minimum threshold
            assert(debt >= rfq_config.min_debt, 'debt-below-min');

            // Check refreeze cooldown
            let snapshot = self.position_snapshots.read((collateral_asset, debt_asset, user));
            let current_time = get_block_timestamp();
            if snapshot.last_unfreeze_at > 0 {
                let cooldown_end = snapshot.last_unfreeze_at + rfq_config.refreeze_cooldown;
                assert(current_time >= cooldown_end, 'refreeze-cooldown-active');
            }

            // Check no active RFQ exists
            let position_key = PositionKey { collateral_asset, debt_asset, user };
            let active_rfq_id = self.active_rfq_by_position.entry(position_key).read();

            if active_rfq_id != 0 {
                let active_rfq = self.rfq_by_id.read(active_rfq_id);
                assert(
                    active_rfq.state != RfqState::Quoting && active_rfq.state != RfqState::QuoteSelected,
                    'rfq-already-active',
                );
            }

            // Calculate debt and collateral amounts
            let debt_amount = calculate_debt(
                ctx.position.nominal_debt,
                ctx.debt_asset_config.last_rate_accumulator,
                ctx.debt_asset_config.scale,
                true,
            );
            let collateral_amount = calculate_collateral(
                ctx.position.collateral_shares, ctx.collateral_asset_config, false,
            );

            // Create and store position snapshot
            let new_snapshot = PositionSnapshot {
                frozen_at: current_time,
                rate_accumulator: ctx.debt_asset_config.last_rate_accumulator,
                collateral_price: ctx.collateral_asset_price.value,
                debt_price: ctx.debt_asset_price.value,
                last_unfreeze_at: snapshot.last_unfreeze_at,
            };
            self.position_snapshots.write((collateral_asset, debt_asset, user), new_snapshot);

            // Lock position in Pool
            pool.lock_position(collateral_asset, debt_asset, user);

            // Create RFQ
            let rfq_id = self.next_rfq_id.read();
            self.next_rfq_id.write(rfq_id + 1);

            let quoting_deadline = current_time + rfq_config.quote_period;
            let settlement_deadline = quoting_deadline + rfq_config.settlement_period;

            let rfq = Rfq {
                rfq_id,
                collateral_asset,
                debt_asset,
                user,
                debt_amount,
                collateral_amount,
                frozen_at: current_time,
                collateral_price: ctx.collateral_asset_price.value,
                debt_price: ctx.debt_asset_price.value,
                collateral_scale: ctx.collateral_asset_config.scale,
                debt_scale: ctx.debt_asset_config.scale,
                created_at: current_time,
                quoting_deadline,
                settlement_deadline,
                state: RfqState::Quoting,
                winner: Zero::zero(),
                winning_quote_id: 0,
                winning_collateral_out: 0,
            };

            // Store RFQ
            self.rfq_by_id.write(rfq_id, rfq);
            self.active_rfq_by_position.entry(position_key).write(rfq_id);
            self.quote_count_by_rfq.write(rfq_id, 0);

            // Emit event
            self
                .emit(
                    RfqCreated {
                        rfq_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        debt_amount,
                        collateral_amount,
                        collateral_price: ctx.collateral_asset_price.value,
                        debt_price: ctx.debt_asset_price.value,
                        frozen_at: current_time,
                        quoting_deadline,
                        settlement_deadline,
                    },
                );

            rfq_id
        }

        fn submit_quote(ref self: ContractState, rfq_id: u64, collateral_out: u256) -> u64 {
            let caller = get_caller_address();

            // Check liquidator is whitelisted
            assert(self.is_whitelisted.read(caller), 'not-whitelisted');

            // Enforce single quote per liquidator per RFQ
            assert(!self.has_quoted.read((rfq_id, caller)), 'already-quoted');

            // Load RFQ
            let rfq = self.rfq_by_id.read(rfq_id);
            assert(rfq.state == RfqState::Quoting, 'not-in-quoting');

            // Check timing
            let now = get_block_timestamp();
            assert(now <= rfq.quoting_deadline, 'quoting-ended');

            // Validate collateral_out
            assert(collateral_out > 0, 'invalid-collateral-out');
            assert(collateral_out <= rfq.collateral_amount, 'exceeds-available-collateral');

            // Check quote count limit
            // Note: reads rfq_config at call time — config changes by curator affect in-progress RFQs
            let rfq_config = self.rfq_configs.read((rfq.collateral_asset, rfq.debt_asset));
            let current_quote_count = self.quote_count_by_rfq.read(rfq_id);
            assert(current_quote_count < rfq_config.max_quotes, 'max-quotes-reached');

            // Validate quote doesn't exceed max_bonus
            // Normalize for different asset scales: debt_value_in_collateral =
            //   (debt_amount * debt_price * collateral_scale) / (debt_scale * collateral_price)
            let debt_value_in_collateral = (rfq.debt_amount * rfq.debt_price * rfq.collateral_scale)
                / (rfq.debt_scale * rfq.collateral_price);
            let max_collateral_out = (debt_value_in_collateral * rfq_config.max_bonus.into()) / SCALE;

            assert(collateral_out <= max_collateral_out, 'quote-exceeds-max-bonus');

            // Create quote
            let quote_id = self.next_quote_id.read();
            self.next_quote_id.write(quote_id + 1);

            let quote = Quote { quote_id, rfq_id, liquidator: caller, collateral_out, created_at: now };

            // Store quote
            self.quote_by_id.write(quote_id, quote);
            self.has_quoted.write((rfq_id, caller), true);

            let idx = self.quote_count_by_rfq.read(rfq_id);
            self.quote_ids_by_rfq.write((rfq_id, idx), quote_id);
            self.quote_count_by_rfq.write(rfq_id, idx + 1);

            // Emit event
            self.emit(QuoteSubmitted { rfq_id, quote_id, liquidator: caller, collateral_out });

            quote_id
        }

        fn select_best_quote(ref self: ContractState, rfq_id: u64) -> u64 {
            // Load RFQ
            let mut rfq = self.rfq_by_id.read(rfq_id);
            assert(rfq.state == RfqState::Quoting, 'not-in-quoting');

            // Get quote count
            let quote_count = self.quote_count_by_rfq.read(rfq_id);
            assert(quote_count > 0, 'no-quotes-submitted');

            // Allow selection if quoting period ended OR max_quotes reached
            // Note: reads rfq_config at call time — config changes by curator affect in-progress RFQs
            let now = get_block_timestamp();
            let rfq_config = self.rfq_configs.read((rfq.collateral_asset, rfq.debt_asset));
            assert(now > rfq.quoting_deadline || quote_count >= rfq_config.max_quotes, 'quoting-not-ended');

            // Find best quote (lowest collateral_out). On ties, the earlier quote wins (first-come advantage).
            let mut best_quote_id: u64 = 0;
            let mut best_collateral_out: u256 = Bounded::MAX;
            let mut best_liquidator: ContractAddress = Zero::zero();

            let mut i: u64 = 0;
            while i < quote_count {
                let quote_id = self.quote_ids_by_rfq.read((rfq_id, i));
                let quote = self.quote_by_id.read(quote_id);

                if quote.collateral_out < best_collateral_out {
                    best_quote_id = quote_id;
                    best_collateral_out = quote.collateral_out;
                    best_liquidator = quote.liquidator;
                }

                i += 1;
            }

            // Update RFQ with winner
            rfq.state = RfqState::QuoteSelected;
            rfq.winner = best_liquidator;
            rfq.winning_quote_id = best_quote_id;
            rfq.winning_collateral_out = best_collateral_out;
            self.rfq_by_id.write(rfq_id, rfq);

            // Emit event
            self
                .emit(
                    QuoteSelected {
                        rfq_id,
                        quote_id: best_quote_id,
                        winner: best_liquidator,
                        winning_collateral_out: best_collateral_out,
                    },
                );

            best_quote_id
        }

        fn settle_liquidation(ref self: ContractState, rfq_id: u64) {
            let caller = get_caller_address();

            // Load RFQ
            let mut rfq = self.rfq_by_id.read(rfq_id);
            assert(rfq.state == RfqState::QuoteSelected, 'not-ready-to-settle');

            // Ensure settlement deadline not passed
            let now = get_block_timestamp();
            assert(now <= rfq.settlement_deadline, 'settlement-period-expired');

            // Check caller is winner
            assert(caller == rfq.winner, 'not-winner');

            let pool_address = self.pool.read();
            let pool = IPoolDispatcher { contract_address: pool_address };

            // Compute frozen_debt (debt at freeze time, already stored in rfq.debt_amount)
            let frozen_debt = rfq.debt_amount;

            // Compute current debt to find accrued interest
            let (position, _, _) = pool.position(rfq.collateral_asset, rfq.debt_asset, rfq.user);
            let current_rate_accumulator = pool.rate_accumulator(rfq.debt_asset);
            let current_debt = calculate_debt(position.nominal_debt, current_rate_accumulator, rfq.debt_scale, true);
            let accrued_interest = current_debt - frozen_debt;

            // Verify collateral sufficiency: the shares-to-assets rate may have changed since RFQ creation
            // (e.g. due to bad debt socialization), so the actual collateral could be less than rfq.collateral_amount
            let collateral_asset_config = pool.asset_config(rfq.collateral_asset);
            let current_collateral = calculate_collateral(position.collateral_shares, collateral_asset_config, false);
            assert(rfq.winning_collateral_out <= current_collateral, 'insufficient-collateral');

            // Compute bad debt from collateral shortfall at frozen prices
            let collateral_value = (rfq.collateral_amount * rfq.collateral_price) / rfq.collateral_scale;
            let frozen_debt_value = (frozen_debt * rfq.debt_price) / rfq.debt_scale;
            let bad_debt = if frozen_debt_value > collateral_value {
                frozen_debt - ((collateral_value * rfq.debt_scale) / rfq.debt_price)
            } else {
                0
            };

            // debt_to_repay = frozen_debt - bad_debt (what the liquidator actually pays)
            let debt_to_repay = frozen_debt - bad_debt;

            // Transfer debt tokens from winner before updating state. This ensures that during
            // a potential ERC20 transfer hook, the active_rfq is still set, preventing reentrancy
            // from creating orphaned RFQs via create_rfq.
            let this_address = get_contract_address();
            IERC20Dispatcher { contract_address: rfq.debt_asset }.transfer_from(caller, this_address, debt_to_repay);

            // Approve Pool to pull debt_to_repay
            IERC20Dispatcher { contract_address: rfq.debt_asset }.approve(pool_address, debt_to_repay);

            // Update RFQ state
            rfq.state = RfqState::Settled;
            self.rfq_by_id.write(rfq_id, rfq);
            let position_key = PositionKey {
                collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user,
            };
            self.active_rfq_by_position.entry(position_key).write(0);

            // Call Pool.settle_liquidation (also unlocks position)
            let (_, _, response_bad_debt) = pool
                .settle_liquidation(
                    rfq.collateral_asset,
                    rfq.debt_asset,
                    rfq.user,
                    rfq.winning_collateral_out,
                    frozen_debt,
                    bad_debt,
                    accrued_interest,
                );

            // Transfer winning collateral to winner
            IERC20Dispatcher { contract_address: rfq.collateral_asset }
                .transfer(rfq.winner, rfq.winning_collateral_out);

            // Clear local snapshot
            self.position_snapshots.write((rfq.collateral_asset, rfq.debt_asset, rfq.user), Default::default());

            // Emit event
            self
                .emit(
                    LiquidationSettled {
                        rfq_id,
                        winner: rfq.winner,
                        collateral_asset: rfq.collateral_asset,
                        debt_asset: rfq.debt_asset,
                        user: rfq.user,
                        debt_amount: frozen_debt,
                        collateral_received: rfq.winning_collateral_out,
                        bad_debt: response_bad_debt,
                    },
                );
        }

        fn set_whitelisted(ref self: ContractState, liquidator: ContractAddress, allowed: bool) {
            assert(get_caller_address() == self.curator.read(), 'not-curator');
            self.is_whitelisted.write(liquidator, allowed);
            self.emit(LiquidatorWhitelisted { liquidator, whitelisted: allowed });
        }

        fn set_rfq_config(
            ref self: ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, config: RfqConfig,
        ) {
            assert(get_caller_address() == self.curator.read(), 'not-curator');
            assert(config.quote_period > 0, 'invalid-quote-period');
            assert(config.settlement_period > 0, 'invalid-settlement-period');
            assert(config.max_bonus.into() >= SCALE, 'max-bonus-below-100-percent');
            assert(config.max_quotes > 0, 'invalid-max-quotes');
            self.rfq_configs.write((collateral_asset, debt_asset), config);
            self
                .emit(
                    RfqConfigSet {
                        collateral_asset,
                        debt_asset,
                        quote_period: config.quote_period,
                        settlement_period: config.settlement_period,
                        max_bonus: config.max_bonus,
                        refreeze_cooldown: config.refreeze_cooldown,
                        max_quotes: config.max_quotes,
                        min_debt: config.min_debt,
                    },
                );
        }

        // cancel_rfq is permissionless and is the sole path for unlocking expired/timed-out RFQs.
        // Note: RFQs in Quoting state with existing quotes cannot be cancelled directly. In that case
        // select_best_quote (permissionless) must be called first, followed by settlement_period expiry,
        // before cancel_rfq becomes callable via the settlement_expired path.
        fn cancel_rfq(ref self: ContractState, rfq_id: u64) {
            let mut rfq = self.rfq_by_id.read(rfq_id);
            let now = get_block_timestamp();

            // Check if RFQ can be cancelled and determine reason
            let is_quoting_expired = rfq.state == RfqState::Quoting
                && now > rfq.quoting_deadline
                && self.quote_count_by_rfq.read(rfq_id) == 0;
            let is_settlement_expired = rfq.state == RfqState::QuoteSelected && now > rfq.settlement_deadline;

            assert(is_quoting_expired || is_settlement_expired, 'cannot-cancel-rfq');

            // Expire RFQ
            rfq.state = RfqState::Expired;
            self.rfq_by_id.write(rfq_id, rfq);
            let position_key = PositionKey {
                collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user,
            };
            self.active_rfq_by_position.entry(position_key).write(0);

            // Update local snapshot (unfreeze)
            let updated_snapshot = PositionSnapshot {
                frozen_at: 0, rate_accumulator: 0, collateral_price: 0, debt_price: 0, last_unfreeze_at: now,
            };
            self.position_snapshots.write((rfq.collateral_asset, rfq.debt_asset, rfq.user), updated_snapshot);

            // Unlock position in Pool
            let pool = IPoolDispatcher { contract_address: self.pool.read() };
            pool.unlock_position(rfq.collateral_asset, rfq.debt_asset, rfq.user);

            if is_quoting_expired {
                self
                    .emit(
                        QuotingExpired {
                            rfq_id, collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user,
                        },
                    );
            } else {
                self
                    .emit(
                        SettlementExpired {
                            rfq_id,
                            collateral_asset: rfq.collateral_asset,
                            debt_asset: rfq.debt_asset,
                            user: rfq.user,
                            winner: rfq.winner,
                            winning_collateral_out: rfq.winning_collateral_out,
                        },
                    );
            }
        }

        fn set_curator(ref self: ContractState, curator: ContractAddress) {
            assert(get_caller_address() == self.curator.read(), 'not-curator');
            self.curator.write(curator);
            self.emit(CuratorSet { curator });
        }

        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu RFQ Module'
        }

        fn upgrade(ref self: ContractState, new_implementation: ClassHash) {
            self.ownable.assert_only_owner();
            replace_class_syscall(new_implementation).unwrap_syscall();
            let new_name = IRfqModuleDispatcher { contract_address: get_contract_address() }.upgrade_name();
            assert(new_name == self.upgrade_name(), 'invalid upgrade name');
            self.emit(ContractUpgraded { new_implementation });
        }

        // ============ View Functions ============

        fn get_rfq(self: @ContractState, rfq_id: u64) -> Rfq {
            self.rfq_by_id.read(rfq_id)
        }

        fn get_active_rfq_id(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
        ) -> u64 {
            let position_key = PositionKey { collateral_asset, debt_asset, user };
            self.active_rfq_by_position.entry(position_key).read()
        }

        fn get_quote(self: @ContractState, quote_id: u64) -> Quote {
            self.quote_by_id.read(quote_id)
        }

        fn get_quotes_for_rfq(self: @ContractState, rfq_id: u64, offset: u64, limit: u64) -> Array<u64> {
            let quote_count = self.quote_count_by_rfq.read(rfq_id);
            let mut quotes = ArrayTrait::new();

            let end = if offset + limit < quote_count {
                offset + limit
            } else {
                quote_count
            };
            let mut i = offset;
            while i < end {
                quotes.append(self.quote_ids_by_rfq.read((rfq_id, i)));
                i += 1;
            }

            quotes
        }

        fn is_liquidator_whitelisted(self: @ContractState, liquidator: ContractAddress) -> bool {
            self.is_whitelisted.read(liquidator)
        }

        fn rfq_config(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress,
        ) -> RfqConfig {
            self.rfq_configs.read((collateral_asset, debt_asset))
        }

        fn position_snapshot(
            self: @ContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
        ) -> PositionSnapshot {
            self.position_snapshots.read((collateral_asset, debt_asset, user))
        }

        fn curator(self: @ContractState) -> ContractAddress {
            self.curator.read()
        }

        fn pool(self: @ContractState) -> ContractAddress {
            self.pool.read()
        }
    }
}
