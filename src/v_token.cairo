use starknet::ContractAddress;

#[starknet::interface]
pub trait IERC4626<TContractState> {
    fn asset(self: @TContractState) -> ContractAddress;
    fn total_assets(self: @TContractState) -> u256;
    fn convert_to_shares(self: @TContractState, assets: u256) -> u256;
    fn convert_to_assets(self: @TContractState, shares: u256) -> u256;
    fn max_deposit(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_deposit(self: @TContractState, assets: u256) -> u256;
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn max_mint(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_mint(self: @TContractState, shares: u256) -> u256;
    fn mint(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;
    fn max_withdraw(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_withdraw(self: @TContractState, assets: u256) -> u256;
    fn withdraw(ref self: TContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress) -> u256;
    fn max_redeem(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_redeem(self: @TContractState, shares: u256) -> u256;
    fn redeem(ref self: TContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress) -> u256;
}

#[starknet::interface]
pub trait IVToken<TContractState> {
    fn pool_contract(self: @TContractState) -> ContractAddress;
    fn approve_pool(ref self: TContractState);
}
#[starknet::contract]
pub mod VToken {
    use alexandria_math::i257::I257Trait;
    use core::num::traits::{Bounded, Zero};
    use openzeppelin::token::erc20::{
        DefaultConfig, ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait, ERC20Component,
        ERC20HooksEmptyImpl,
    };
    use openzeppelin::utils::math::{Rounding, u256_mul_div};
    use starknet::event::EventEmitter;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, ModifyPositionParams, UpdatePositionResponse};
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait, IPoolSafeDispatcher, IPoolSafeDispatcherTrait};
    use vesu::units::SCALE;
    use vesu::v_token::{IERC4626, IVToken};

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;

    #[storage]
    struct Storage {
        // the address of the pool contract
        pool_contract: ContractAddress,
        // the address of the underlying asset of the vToken
        asset: ContractAddress,
        // the address of the debt asset of the position owned by the vToken
        debt_asset: ContractAddress,
        // flag indicating whether the asset is a legacy ERC20 token using camelCase or snake_case
        is_legacy: bool,
        // storage for the erc20 component
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        sender: ContractAddress,
        #[key]
        owner: ContractAddress,
        assets: u256,
        shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        #[key]
        sender: ContractAddress,
        #[key]
        receiver: ContractAddress,
        #[key]
        owner: ContractAddress,
        assets: u256,
        shares: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        Deposit: Deposit,
        Withdraw: Withdraw,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        pool_contract: ContractAddress,
        asset: ContractAddress,
        debt_asset: ContractAddress,
    ) {
        self.erc20.initializer(name, symbol);
        self.pool_contract.write(pool_contract);
        self.asset.write(asset);
        self.debt_asset.write(debt_asset);
        self.approve_pool();
        let asset_config = self.pool().asset_config(asset);
        self.is_legacy.write(asset_config.is_legacy);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        /// Returns the pool contract dispatcher
        fn pool(self: @ContractState) -> IPoolDispatcher {
            IPoolDispatcher { contract_address: self.pool_contract.read() }
        }

        /// Returns true if the pool accepts deposits
        fn can_modify_position(self: @ContractState) -> bool {
            let pool = IPoolSafeDispatcher { contract_address: self.pool_contract.read() };

            #[feature("safe_dispatcher")]
            let invariants = pool
                .check_invariants(
                    self.asset.read(),
                    self.debt_asset.read(),
                    get_contract_address(),
                    Zero::zero(),
                    Zero::zero(),
                    Zero::zero(),
                    Zero::zero(),
                    false,
                )
                .is_ok();

            invariants && !self.pool().is_paused()
        }

        /// See the `calculate_withdrawable_assets`
        fn calculate_withdrawable_assets(self: @ContractState) -> u256 {
            let asset = self.asset.read();
            let asset_config = self.pool().asset_config(asset);

            let total_debt = self
                .pool()
                .calculate_debt(
                    I257Trait::new(asset_config.total_nominal_debt, is_negative: false),
                    asset_config.last_rate_accumulator,
                    asset_config.scale,
                );

            // Add 1 to the utilization returned by the pool to round it up
            if self.pool().utilization(asset) + 1 >= asset_config.max_utilization {
                return 0;
            }

            // Let x be the max amount that can be withdrawn
            // After withdrawing `x` from the collateral, the reserve will be:
            //    reserve - x
            // Then, the utilization must be equal to `max_utilization`, so:
            //    total_debt / ((reserve - x) + total_debt) = max_utilization
            // Solving for `x` gives:
            //    x = (reserve + total_debt) - total_debt / max_utilization
            (asset_config.reserve + total_debt)
                - u256_mul_div(total_debt, SCALE, asset_config.max_utilization, Rounding::Ceil)
        }

        /// Transfers an amount of assets from sender to receiver
        fn transfer_asset(self: @ContractState, sender: ContractAddress, to: ContractAddress, amount: u256) {
            let asset = self.asset.read();
            let is_legacy = self.is_legacy.read();
            let erc20 = IERC20Dispatcher { contract_address: asset };
            if sender == get_contract_address() {
                assert!(erc20.transfer(to, amount), "transfer-failed");
            } else if is_legacy {
                assert!(erc20.transferFrom(sender, to, amount), "transferFrom-failed");
            } else {
                assert!(erc20.transfer_from(sender, to, amount), "transfer-from-failed");
            }
        }
    }

    #[abi(embed_v0)]
    impl VTokenImpl of IVToken<ContractState> {
        /// Returns the address of the pool associated with the vToken
        /// # Returns
        /// * address of the pool
        fn pool_contract(self: @ContractState) -> ContractAddress {
            self.pool_contract.read()
        }

        /// Approves the pool contract to spend the underlying asset of the vToken
        fn approve_pool(ref self: ContractState) {
            assert!(
                IERC20Dispatcher { contract_address: self.asset.read() }
                    .approve(self.pool_contract.read(), Bounded::<u256>::MAX),
                "approve-failed",
            );
        }
    }

    #[abi(embed_v0)]
    impl ERC4626Impl of IERC4626<ContractState> {
        /// Returns the address of the underlying asset of the vToken
        /// # Returns
        /// * address of the asset
        fn asset(self: @ContractState) -> ContractAddress {
            self.asset.read()
        }

        /// Returns the total amount of underlying assets deposited via the vToken
        /// # Returns
        /// * total amount of assets [asset scale]
        fn total_assets(self: @ContractState) -> u256 {
            let shares = I257Trait::new(self.erc20.total_supply(), is_negative: true);
            self.pool().calculate_collateral(self.asset.read(), shares)
        }

        /// Converts an amount of assets to the equivalent amount of vToken shares
        /// # Arguments
        /// * `assets` - amount of assets to convert [asset scale]
        /// # Returns
        /// * amount of vToken shares [SCALE]
        fn convert_to_shares(self: @ContractState, assets: u256) -> u256 {
            let amount_i257 = I257Trait::new(assets, is_negative: false);
            self.pool().calculate_collateral_shares(self.asset.read(), amount_i257)
        }

        /// Converts an amount of vToken shares to the equivalent amount of assets
        /// # Arguments
        /// * `shares` - amount of vToken shares to convert [SCALE]
        /// # Returns
        /// * amount of assets [asset scale]
        fn convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            let shares_i257 = I257Trait::new(shares, is_negative: true);
            self.pool().calculate_collateral(self.asset.read(), shares_i257)
        }

        /// Returns the maximum amount of assets that can be deposited via the vToken
        /// # Arguments
        /// * `receiver` - address to receive the vToken shares
        /// # Returns
        /// * maximum amount of assets [asset scale]
        fn max_deposit(self: @ContractState, receiver: ContractAddress) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }
            let asset_config = self.pool().asset_config(self.asset.read());
            let room = Bounded::<u128>::MAX.into() - asset_config.total_collateral_shares;
            self.pool().calculate_collateral(self.asset.read(), I257Trait::new(room, is_negative: false))
        }

        /// Returns the amount of vToken shares that will be minted for the given amount of deposited assets
        /// # Arguments
        /// * `assets` - amount of assets to deposit [asset scale]
        /// # Returns
        /// * amount of vToken shares minted [SCALE]
        fn preview_deposit(self: @ContractState, assets: u256) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }
            self.pool().calculate_collateral_shares(self.asset.read(), I257Trait::new(assets, is_negative: false))
        }

        /// Deposits assets into the pool and mints vTokens (shares) to the receiver
        /// # Arguments
        /// * `assets` - amount of assets to deposit [asset scale]
        /// * `receiver` - address to receive the vToken shares
        /// # Returns
        /// * amount of vToken shares minted [SCALE]
        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            let v_token_address = get_contract_address();
            let caller = get_caller_address();

            // Transfer assets to the vToken contract
            self.transfer_asset(caller, v_token_address, assets);

            let params = ModifyPositionParams {
                collateral_asset: self.asset.read(),
                debt_asset: self.debt_asset.read(),
                user: v_token_address,
                collateral: Amount {
                    denomination: AmountDenomination::Assets, value: I257Trait::new(assets, is_negative: false),
                },
                debt: Default::default(),
            };

            // Invoke `modify_position` and extract the number of shares minted
            let shares = self.pool().modify_position(params).collateral_shares_delta.abs();

            self.erc20.mint(receiver, shares);

            self.emit(Deposit { sender: caller, owner: receiver, assets, shares });

            shares
        }

        /// Returns the maximum amount of vToken shares that can be minted
        /// # Arguments
        /// * `receiver` - address to receive the vToken shares
        /// # Returns
        /// * maximum amount of vToken shares minted [SCALE]
        fn max_mint(self: @ContractState, receiver: ContractAddress) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }
            let asset_config = self.pool().asset_config(self.asset.read());
            Bounded::<u128>::MAX.into() - asset_config.total_collateral_shares
        }

        /// Returns the amount of assets that will be deposited for a given amount of minted vToken shares
        /// # Arguments
        /// * `shares` - amount of vToken shares to mint [SCALE]
        /// # Returns
        /// * amount of assets deposited [asset scale]
        fn preview_mint(self: @ContractState, shares: u256) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }
            self.pool().calculate_collateral(self.asset.read(), I257Trait::new(shares, is_negative: false))
        }

        /// Mints vToken shares to the receiver by depositing assets into the pool
        /// # Arguments
        /// * `shares` - amount of vToken shares to mint [SCALE]
        /// * `receiver` - address to receive the vToken shares
        /// # Returns
        /// * amount of assets deposited [asset scale]
        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            let v_token_address = get_contract_address();
            let caller = get_caller_address();

            let assets_estimate = self
                .pool()
                .calculate_collateral(self.asset.read(), I257Trait::new(shares, is_negative: false));

            // Transfer an estimated amount of assets to the vToken contract to ensure that minting
            // of vTokens happens after the deposit
            self.transfer_asset(caller, v_token_address, assets_estimate);

            let params = ModifyPositionParams {
                collateral_asset: self.asset.read(),
                debt_asset: self.debt_asset.read(),
                user: v_token_address,
                collateral: Amount {
                    denomination: AmountDenomination::Native, value: I257Trait::new(shares, is_negative: false),
                },
                debt: Default::default(),
            };

            // Invoke `modify_position` and extract the actual amount of assets deposited
            let response = self.pool().modify_position(params);
            let assets = response.collateral_delta.abs();
            let shares = response.collateral_shares_delta.abs();

            self.erc20.mint(receiver, shares);

            // refund the difference between the estimated and actual amount of assets
            self.transfer_asset(v_token_address, caller, assets_estimate - assets);

            self.emit(Deposit { sender: caller, owner: receiver, assets, shares });

            assets
        }

        /// Returns the maximum amount of assets that can be withdrawn by the owner of the vToken shares
        /// # Arguments
        /// * `owner` - address of the owner of the vToken shares
        /// # Returns
        /// * maximum amount of assets [asset scale]
        fn max_withdraw(self: @ContractState, owner: ContractAddress) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }

            let room = self.calculate_withdrawable_assets();
            let assets = self
                .pool()
                .calculate_collateral(
                    self.asset.read(), I257Trait::new(self.erc20.balance_of(owner), is_negative: true),
                );

            if assets > room {
                room
            } else {
                assets
            }
        }

        /// Returns the amount of vToken shares that will be burned for a given amount of withdrawn assets
        /// # Arguments
        /// * `assets` - amount of assets to withdraw [asset scale]
        /// # Returns
        /// * amount of vToken shares burned [SCALE]
        fn preview_withdraw(self: @ContractState, assets: u256) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }
            self.pool().calculate_collateral_shares(self.asset.read(), I257Trait::new(assets, is_negative: true))
        }

        /// Withdraws assets from the pool and burns vTokens (shares) from the owner of the vTokens
        /// # Arguments
        /// * `assets` - amount of assets to withdraw [asset scale]
        /// * `receiver` - address to receive the withdrawn assets
        /// * `owner` - address of the owner of the vToken shares
        /// # Returns
        /// * amount of vTokens (shares) burned [SCALE]
        fn withdraw(ref self: ContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress) -> u256 {
            let v_token_address = get_contract_address();
            let caller = get_caller_address();

            let params = ModifyPositionParams {
                collateral_asset: self.asset.read(),
                debt_asset: self.debt_asset.read(),
                user: v_token_address,
                collateral: Amount {
                    denomination: AmountDenomination::Assets, value: I257Trait::new(assets, is_negative: true),
                },
                debt: Default::default(),
            };

            // Invoke `modify_position` and extract the number of shares burned
            let UpdatePositionResponse {
                collateral_shares_delta, collateral_delta, ..,
            } = self.pool().modify_position(params);
            assert!(collateral_delta.abs() == assets, "insufficient-assets");
            let shares = collateral_shares_delta.abs();

            // If the withdrawal is done on behalf of the owner, we need to spend the allowance
            if caller != owner {
                self.erc20._spend_allowance(owner, caller, shares);
            }
            self.erc20.burn(owner, shares);

            self.transfer_asset(v_token_address, receiver, assets);

            self.emit(Withdraw { sender: caller, receiver, owner, assets, shares });

            shares
        }

        /// Returns the maximum amount of vToken shares that can be redeemed by the owner of the vTokens (shares)
        /// # Arguments
        /// * `owner` - address of the owner
        /// # Returns
        /// * maximum amount of vToken shares [SCALE]
        fn max_redeem(self: @ContractState, owner: ContractAddress) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }
            let room = self
                .pool()
                .calculate_collateral_shares(
                    self.asset.read(), I257Trait::new(self.calculate_withdrawable_assets(), is_negative: true),
                );
            let shares = self.erc20.balance_of(owner);

            if shares > room {
                room
            } else {
                shares
            }
        }

        /// Returns the amount of assets that will be withdrawn for a given amount of redeemed / burned vTokens (shares)
        /// # Arguments
        /// * `shares` - amount of vToken shares to redeem [SCALE]
        /// # Returns
        /// * amount of assets withdrawn [asset scale]
        fn preview_redeem(self: @ContractState, shares: u256) -> u256 {
            if !self.can_modify_position() {
                return 0;
            }
            self.pool().calculate_collateral(self.asset.read(), I257Trait::new(shares, is_negative: true))
        }

        /// Redeems / burns vTokens (shares) from the owner and withdraws assets from the pool
        /// # Arguments
        /// * `shares` - amount of vToken shares to redeem [SCALE]
        /// * `receiver` - address to receive the withdrawn assets
        /// * `owner` - address of the owner of the vToken shares
        /// # Returns
        /// * amount of assets withdrawn [asset scale]
        fn redeem(ref self: ContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress) -> u256 {
            let v_token_address = get_contract_address();
            let caller = get_caller_address();

            // If the redemption is done on behalf of the owner, we need to spend the allowance
            if caller != owner {
                self.erc20._spend_allowance(owner, caller, shares);
            }
            self.erc20.burn(owner, shares);

            let params = ModifyPositionParams {
                collateral_asset: self.asset.read(),
                debt_asset: self.debt_asset.read(),
                user: v_token_address,
                collateral: Amount {
                    denomination: AmountDenomination::Native, value: I257Trait::new(shares, is_negative: true),
                },
                debt: Default::default(),
            };

            // Invoke `modify_position` and extract the amount of assets withdrawn
            let assets = self.pool().modify_position(params).collateral_delta.abs();

            self.transfer_asset(v_token_address, receiver, assets);

            self.emit(Withdraw { sender: caller, receiver, owner, assets, shares });

            assets
        }
    }
}
