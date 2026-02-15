use starknet::{ClassHash, ContractAddress};

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
    fn expire_rfq(ref self: TContractState, rfq_id: u64);

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
    use vesu::common::{calculate_collateral, calculate_debt};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::rfq_module::{IRfqModuleDispatcher, IRfqModuleDispatcherTrait};
    use vesu::units::SCALE;
    use super::{IRfqModule, PositionKey, Quote, Rfq, RfqState};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[storage]
    struct Storage {
        pool: ContractAddress,
        curator: ContractAddress,
        is_whitelisted: Map<ContractAddress, bool>,
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
        collateral_paid_to_winner: u256,
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

            // Load position snapshot from Pool
            let snapshot = pool.position_snapshot(collateral_asset, debt_asset, user);
            assert(snapshot.frozen_at != 0, 'position-not-frozen');

            // Load position from Pool (for collateral_shares and nominal_debt)
            let (position, _, _) = pool.position(collateral_asset, debt_asset, user);

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

            // Load RFQ config from Pool
            let rfq_config = pool.rfq_config(collateral_asset, debt_asset);
            assert(rfq_config.quote_period > 0, 'rfq-not-configured');

            // Calculate debt and collateral amounts using common functions
            let debt_asset_config = pool.asset_config(debt_asset);
            let collateral_asset_config = pool.asset_config(collateral_asset);
            let debt_amount = calculate_debt(
                position.nominal_debt, snapshot.rate_accumulator, debt_asset_config.scale, true,
            );
            let collateral_amount = calculate_collateral(position.collateral_shares, collateral_asset_config, false);

            // Create RFQ
            let rfq_id = self.next_rfq_id.read();
            self.next_rfq_id.write(rfq_id + 1);

            let quoting_deadline = snapshot.frozen_at + rfq_config.quote_period;
            let settlement_deadline = quoting_deadline + rfq_config.settlement_period;

            let rfq = Rfq {
                rfq_id,
                collateral_asset,
                debt_asset,
                user,
                debt_amount,
                collateral_amount,
                frozen_at: snapshot.frozen_at,
                collateral_price: snapshot.collateral_price,
                debt_price: snapshot.debt_price,
                collateral_scale: collateral_asset_config.scale,
                debt_scale: debt_asset_config.scale,
                created_at: get_block_timestamp(),
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
                        collateral_price: snapshot.collateral_price,
                        debt_price: snapshot.debt_price,
                        frozen_at: snapshot.frozen_at,
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
            let pool = IPoolDispatcher { contract_address: self.pool.read() };
            let rfq_config = pool.rfq_config(rfq.collateral_asset, rfq.debt_asset);
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
            let now = get_block_timestamp();
            let pool = IPoolDispatcher { contract_address: self.pool.read() };
            let rfq_config = pool.rfq_config(rfq.collateral_asset, rfq.debt_asset);
            assert(now > rfq.quoting_deadline || quote_count >= rfq_config.max_quotes, 'quoting-not-ended');

            // Find best quote (lowest collateral_out)
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

            // Transfer debt tokens from winner before updating state. This ensures that during
            // a potential ERC20 transfer hook, the active_rfq is still set, preventing reentrancy
            // from creating orphaned RFQs via create_rfq.
            let this_address = get_contract_address();
            let pool_address = self.pool.read();
            IERC20Dispatcher { contract_address: rfq.debt_asset }.transfer_from(caller, this_address, rfq.debt_amount);

            // Approve Pool to pull debt tokens
            IERC20Dispatcher { contract_address: rfq.debt_asset }.approve(pool_address, rfq.debt_amount);

            // Update RFQ state
            rfq.state = RfqState::Settled;
            self.rfq_by_id.write(rfq_id, rfq);
            let position_key = PositionKey {
                collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user,
            };
            self.active_rfq_by_position.entry(position_key).write(0);

            // Call Pool.settle_liquidation
            let pool = IPoolDispatcher { contract_address: pool_address };
            let (_, _, collateral_asset, collateral_received, bad_debt) = pool
                .settle_liquidation(rfq.collateral_asset, rfq.debt_asset, rfq.user, rfq.winning_collateral_out);

            // Transfer winning collateral to winner
            IERC20Dispatcher { contract_address: collateral_asset }.transfer(rfq.winner, rfq.winning_collateral_out);

            // Refund excess debt tokens to winner when bad_debt > 0. The pool only pulls
            // (frozen_debt - bad_debt) from this contract, leaving bad_debt tokens stranded.
            if bad_debt > 0 {
                IERC20Dispatcher { contract_address: rfq.debt_asset }.transfer(rfq.winner, bad_debt);
            }

            // Emit event
            self
                .emit(
                    LiquidationSettled {
                        rfq_id,
                        winner: rfq.winner,
                        collateral_asset: rfq.collateral_asset,
                        debt_asset: rfq.debt_asset,
                        user: rfq.user,
                        debt_amount: rfq.debt_amount,
                        collateral_received,
                        collateral_paid_to_winner: rfq.winning_collateral_out,
                        bad_debt,
                    },
                );
        }

        fn set_whitelisted(ref self: ContractState, liquidator: ContractAddress, allowed: bool) {
            assert(get_caller_address() == self.curator.read(), 'not-curator');
            self.is_whitelisted.write(liquidator, allowed);
            self.emit(LiquidatorWhitelisted { liquidator, whitelisted: allowed });
        }

        // expire_rfq unfreezes the position
        fn expire_rfq(ref self: ContractState, rfq_id: u64) {
            let mut rfq = self.rfq_by_id.read(rfq_id);
            let now = get_block_timestamp();

            // Check if RFQ can be expired and determine expiry reason
            let is_quoting_expired = rfq.state == RfqState::Quoting
                && now > rfq.quoting_deadline
                && self.quote_count_by_rfq.read(rfq_id) == 0;
            let is_settlement_expired = rfq.state == RfqState::QuoteSelected && now > rfq.settlement_deadline;

            assert(is_quoting_expired || is_settlement_expired, 'cannot-expire-rfq');

            // Expire RFQ
            rfq.state = RfqState::Expired;
            self.rfq_by_id.write(rfq_id, rfq);
            let position_key = PositionKey {
                collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user,
            };
            self.active_rfq_by_position.entry(position_key).write(0);

            // Unfreeze position if still frozen. The position may have already been unfrozen
            // via pool.unfreeze_position directly (after the full RFQ period expired). In that
            // case, skipping the call prevents a revert and allows the RFQ to be properly expired.
            let pool = IPoolDispatcher { contract_address: self.pool.read() };
            let snapshot = pool.position_snapshot(rfq.collateral_asset, rfq.debt_asset, rfq.user);
            if snapshot.frozen_at != 0 {
                pool.unfreeze_position(rfq.collateral_asset, rfq.debt_asset, rfq.user);
            }

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

        fn curator(self: @ContractState) -> ContractAddress {
            self.curator.read()
        }

        fn pool(self: @ContractState) -> ContractAddress {
            self.pool.read()
        }
    }
}
