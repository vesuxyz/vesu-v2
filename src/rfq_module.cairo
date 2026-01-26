use starknet::ContractAddress;

#[starknet::interface]
pub trait IRfqModule<TContractState> {
    // Core RFQ functions
    fn create_rfq(
        ref self: TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> u64;
    fn submit_quote(ref self: TContractState, rfq_id: u64, collateral_out: u256) -> u64;
    fn select_best_quote(ref self: TContractState, rfq_id: u64) -> u64;
    fn settle_liquidation(ref self: TContractState, rfq_id: u64);

    // Admin functions
    fn set_whitelisted(ref self: TContractState, liquidator: ContractAddress, allowed: bool);
    fn expire_rfq(ref self: TContractState, rfq_id: u64);
    fn cancel_rfq(ref self: TContractState, rfq_id: u64);

    // View functions
    fn get_rfq(self: @TContractState, rfq_id: u64) -> Rfq;
    fn get_active_rfq_id(
        self: @TContractState, collateral_asset: ContractAddress, debt_asset: ContractAddress, user: ContractAddress,
    ) -> u64;
    fn get_quote(self: @TContractState, quote_id: u64) -> Quote;
    fn get_quotes_for_rfq(self: @TContractState, rfq_id: u64, offset: u64, limit: u64) -> Array<u64>;
    fn is_liquidator_whitelisted(self: @TContractState, liquidator: ContractAddress) -> bool;
    fn owner(self: @TContractState) -> ContractAddress;
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
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use super::{IRfqModule, PositionKey, Quote, Rfq, RfqState};
    use vesu::data_model::{Position, PositionSnapshot, RfqConfig};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::units::SCALE;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        pool: ContractAddress,
        is_whitelisted: Map<ContractAddress, bool>,
        next_rfq_id: u64,
        next_quote_id: u64,
        rfq_by_id: Map<u64, Rfq>,
        active_rfq_by_position: Map<PositionKey, u64>,
        quote_by_id: Map<u64, Quote>,
        quote_count_by_rfq: Map<u64, u64>,
        quote_ids_by_rfq: Map<(u64, u64), u64>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        RfqCreated: RfqCreated,
        QuoteSubmitted: QuoteSubmitted,
        QuoteSelected: QuoteSelected,
        LiquidationSettled: LiquidationSettled,
        RfqExpired: RfqExpired,
        LiquidatorWhitelisted: LiquidatorWhitelisted,
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
    }

    #[derive(Drop, starknet::Event)]
    struct RfqExpired {
        #[key]
        rfq_id: u64,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct LiquidatorWhitelisted {
        #[key]
        liquidator: ContractAddress,
        whitelisted: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, pool: ContractAddress) {
        self.owner.write(owner);
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

            // Calculate debt and collateral amounts
            let debt_amount = self.calculate_debt_from_position(position.nominal_debt, snapshot.rate_accumulator, pool, debt_asset);
            let collateral_amount = self
                .calculate_collateral_from_position(position.collateral_shares, pool, collateral_asset, debt_asset);

            // Create RFQ
            let rfq_id = self.next_rfq_id.read();
            self.next_rfq_id.write(rfq_id + 1);

            let now = get_block_timestamp();
            let quoting_deadline = now + rfq_config.quote_period;
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
                created_at: now,
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

            // Load RFQ
            let rfq = self.rfq_by_id.read(rfq_id);
            assert(rfq.state == RfqState::Quoting, 'not-in-quoting');

            // Check timing
            let now = get_block_timestamp();
            assert(now <= rfq.quoting_deadline, 'quoting-ended');

            // Validate collateral_out
            assert(collateral_out > 0, 'invalid-collateral-out');
            assert(collateral_out <= rfq.collateral_amount, 'exceeds-available-collateral');

            // Validate quote doesn't exceed max_bonus
            let pool = IPoolDispatcher { contract_address: self.pool.read() };
            let rfq_config = pool.rfq_config(rfq.collateral_asset, rfq.debt_asset);

            let debt_value_in_collateral = (rfq.debt_amount * rfq.debt_price) / rfq.collateral_price;
            let max_collateral_out = (debt_value_in_collateral * rfq_config.max_bonus.into()) / SCALE;

            assert(collateral_out <= max_collateral_out, 'quote-exceeds-max-bonus');

            // Create quote
            let quote_id = self.next_quote_id.read();
            self.next_quote_id.write(quote_id + 1);

            let quote = Quote { quote_id, rfq_id, liquidator: caller, collateral_out, created_at: now, };

            // Store quote
            self.quote_by_id.write(quote_id, quote);

            let idx = self.quote_count_by_rfq.read(rfq_id);
            self.quote_ids_by_rfq.write((rfq_id, idx), quote_id);
            self.quote_count_by_rfq.write(rfq_id, idx + 1);

            // Emit event
            self.emit(QuoteSubmitted { rfq_id, quote_id, liquidator: caller, collateral_out, });

            quote_id
        }

        fn select_best_quote(ref self: ContractState, rfq_id: u64) -> u64 {
            // Load RFQ
            let mut rfq = self.rfq_by_id.read(rfq_id);
            assert(rfq.state == RfqState::Quoting, 'not-in-quoting');

            // Check quoting period has ended
            let now = get_block_timestamp();
            assert(now > rfq.quoting_deadline, 'quoting-not-ended');

            // Get quote count
            let quote_count = self.quote_count_by_rfq.read(rfq_id);

            if quote_count == 0 {
                // No quotes - expire RFQ
                rfq.state = RfqState::Expired;
                self.rfq_by_id.write(rfq_id, rfq);
                self.emit(RfqExpired { rfq_id, collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user, });
                return 0;
            }

            // Find best quote (lowest collateral_out)
            let mut best_quote_id: u64 = 0;
            let mut best_collateral_out: u256 = BoundedInt::max();
            let mut best_liquidator: ContractAddress = Zero::zero();

            let mut i: u64 = 0;
            loop {
                if i >= quote_count {
                    break;
                }

                let quote_id = self.quote_ids_by_rfq.read((rfq_id, i));
                let quote = self.quote_by_id.read(quote_id);

                if quote.collateral_out < best_collateral_out {
                    best_quote_id = quote_id;
                    best_collateral_out = quote.collateral_out;
                    best_liquidator = quote.liquidator;
                }

                i += 1;
            };

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
                        rfq_id, quote_id: best_quote_id, winner: best_liquidator, winning_collateral_out: best_collateral_out,
                    },
                );

            best_quote_id
        }

        fn settle_liquidation(ref self: ContractState, rfq_id: u64) {
            let caller = get_caller_address();

            // Load RFQ
            let mut rfq = self.rfq_by_id.read(rfq_id);
            assert(rfq.state == RfqState::QuoteSelected, 'not-ready-to-settle');

            // Check timing
            let now = get_block_timestamp();
            if now > rfq.settlement_deadline {
                // Settlement period expired - expire RFQ
                rfq.state = RfqState::Expired;
                self.rfq_by_id.write(rfq_id, rfq);
                self.emit(RfqExpired { rfq_id, collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user, });
                return;
            }

            // Check caller is winner
            assert(caller == rfq.winner, 'not-winner');

            // Transfer debt tokens from winner to this contract
            let this_address = get_contract_address();
            IERC20Dispatcher { contract_address: rfq.debt_asset }.transfer_from(caller, this_address, rfq.debt_amount);

            // Approve Pool to pull debt tokens
            IERC20Dispatcher { contract_address: rfq.debt_asset }.approve(self.pool.read(), rfq.debt_amount);

            // Call Pool.settle_liquidation
            let pool = IPoolDispatcher { contract_address: self.pool.read() };
            let (debt_asset, debt_amount, collateral_asset, collateral_received, bad_debt) = pool
                .settle_liquidation(rfq.collateral_asset, rfq.debt_asset, rfq.user, rfq.winning_collateral_out);

            // Transfer winning collateral to winner
            IERC20Dispatcher { contract_address: collateral_asset }.transfer(rfq.winner, rfq.winning_collateral_out);

            // Update RFQ state
            rfq.state = RfqState::Settled;
            self.rfq_by_id.write(rfq_id, rfq);
            let position_key = PositionKey {
                collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user,
            };
            self.active_rfq_by_position.entry(position_key).write(0);

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
                    },
                );
        }

        fn set_whitelisted(ref self: ContractState, liquidator: ContractAddress, allowed: bool) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'not-owner');

            self.is_whitelisted.write(liquidator, allowed);
            self.emit(LiquidatorWhitelisted { liquidator, whitelisted: allowed });
        }

        fn expire_rfq(ref self: ContractState, rfq_id: u64) {
            let mut rfq = self.rfq_by_id.read(rfq_id);
            let now = get_block_timestamp();

            // Check if RFQ can be expired
            let can_expire = if rfq.state == RfqState::Quoting {
                now > rfq.quoting_deadline && self.quote_count_by_rfq.read(rfq_id) == 0
            } else if rfq.state == RfqState::QuoteSelected {
                now > rfq.settlement_deadline
            } else {
                false
            };

            assert(can_expire, 'cannot-expire-rfq');

            // Expire RFQ
            rfq.state = RfqState::Expired;
            self.rfq_by_id.write(rfq_id, rfq);
            self.emit(RfqExpired { rfq_id, collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user, });
        }

        fn cancel_rfq(ref self: ContractState, rfq_id: u64) {
            let mut rfq = self.rfq_by_id.read(rfq_id);
            let now = get_block_timestamp();

            // Check RFQ is in Quoting state
            assert(rfq.state == RfqState::Quoting, 'rfq-not-in-quoting-state');

            // Check quote period has expired
            assert(now > rfq.quoting_deadline, 'quote-period-not-expired');

            // Check no valid quotes were submitted
            assert(self.quote_count_by_rfq.read(rfq_id) == 0, 'quotes-exist-cannot-cancel');

            // Mark RFQ as expired
            rfq.state = RfqState::Expired;
            self.rfq_by_id.write(rfq_id, rfq);

            // Unfreeze position by calling unfreeze_position_early on Pool
            let pool = IPoolDispatcher { contract_address: self.pool.read() };
            pool.unfreeze_position_early(rfq.collateral_asset, rfq.debt_asset, rfq.user);

            // Emit event
            self.emit(
                RfqExpired {
                    rfq_id, collateral_asset: rfq.collateral_asset, debt_asset: rfq.debt_asset, user: rfq.user,
                },
            );
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

            let end = if offset + limit < quote_count { offset + limit } else { quote_count };
            let mut i = offset;

            loop {
                if i >= end {
                    break;
                }
                quotes.append(self.quote_ids_by_rfq.read((rfq_id, i)));
                i += 1;
            };

            quotes
        }

        fn is_liquidator_whitelisted(self: @ContractState, liquidator: ContractAddress) -> bool {
            self.is_whitelisted.read(liquidator)
        }

        fn owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn pool(self: @ContractState) -> ContractAddress {
            self.pool.read()
        }
    }

    // ============ Internal Helper Functions ============

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn calculate_debt_from_position(
            self: @ContractState, nominal_debt: u256, frozen_rate_accumulator: u256, pool: IPoolDispatcher, debt_asset: ContractAddress,
        ) -> u256 {
            let debt_config = pool.asset_config(debt_asset);
            // debt = nominal_debt * frozen_rate_accumulator / scale
            (nominal_debt * frozen_rate_accumulator) / debt_config.scale
        }

        fn calculate_collateral_from_position(
            self: @ContractState,
            collateral_shares: u256,
            pool: IPoolDispatcher,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
        ) -> u256 {
            let collateral_config = pool.asset_config(collateral_asset);
            let pair = pool.pairs(collateral_asset, debt_asset);

            if pair.total_collateral_shares == 0 {
                return 0;
            }

            // collateral = shares * reserve / total_shares
            (collateral_shares * collateral_config.reserve) / pair.total_collateral_shares
        }
    }
}
