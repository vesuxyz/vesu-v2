use starknet::ContractAddress;
use vesu::data_model::{AssetParams, DebtCapParams, LTVParams, LiquidationParams, ShutdownParams, VTokenParams};
use vesu::interest_rate_model::InterestRateConfig;

#[starknet::interface]
pub trait IPoolFactory<TContractState> {
    fn pool_class_hash(self: @TContractState) -> felt252;
    fn v_token_class_hash(self: @TContractState) -> felt252;
    fn v_token_for_asset(self: @TContractState, pool: ContractAddress, asset: ContractAddress) -> ContractAddress;
    fn asset_for_v_token(self: @TContractState, pool: ContractAddress, v_token: ContractAddress) -> ContractAddress;
    fn create_pool(
        ref self: TContractState,
        name: felt252,
        owner: ContractAddress,
        curator: ContractAddress,
        oracle: ContractAddress,
        fee_recipient: ContractAddress,
        shutdown_params: ShutdownParams,
        asset_params: Span<AssetParams>,
        v_token_params: Span<VTokenParams>,
        ltv_params: Span<LTVParams>,
        interest_rate_params: Span<InterestRateConfig>,
        liquidation_params: Span<LiquidationParams>,
        debt_cap_params: Span<DebtCapParams>,
    ) -> ContractAddress;
}


#[starknet::contract]
mod pool_factory {
    use core::num::traits::Zero;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::deploy_syscall;
    use starknet::{ContractAddress, get_contract_address};
    use vesu::data_model::{
        AssetParams, DebtCapParams, LTVParams, LiquidationConfig, LiquidationParams, ShutdownConfig, ShutdownParams,
        VTokenParams,
    };
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::pool_factory::IPoolFactory;

    #[storage]
    struct Storage {
        pool_class_hash: felt252,
        v_token_class_hash: felt252,
        v_token_for_asset: Map<(ContractAddress, ContractAddress), ContractAddress>,
        asset_for_v_token: Map<(ContractAddress, ContractAddress), ContractAddress>,
    }

    #[derive(Drop, starknet::Event)]
    struct CreateVToken {
        #[key]
        pool: ContractAddress,
        #[key]
        asset: ContractAddress,
        #[key]
        v_token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct CreatePool {
        #[key]
        pool: ContractAddress,
        #[key]
        owner: ContractAddress,
        #[key]
        curator: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CreateVToken: CreateVToken,
        CreatePool: CreatePool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, pool_class_hash: felt252) {
        self.pool_class_hash.write(pool_class_hash);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        /// Creates a vToken contract for a given collateral asset.
        /// # Arguments
        /// * `pool_id` - id of the pool
        /// * `collateral_asset` - address of the collateral asset
        /// * `v_token_name` - name of the vToken
        /// * `v_token_symbol` - symbol of the vToken
        fn create_v_token(
            ref self: ContractState,
            pool: ContractAddress,
            asset: ContractAddress,
            v_token_name: felt252,
            v_token_symbol: felt252,
        ) {
            assert!(self.v_token_for_asset.read((pool, asset)) == Zero::zero(), "v-token-already-created");

            let (v_token, _) = (deploy_syscall(
                self.v_token_class_hash.read().try_into().unwrap(),
                0,
                array![v_token_name, v_token_symbol, pool.into(), get_contract_address().into(), asset.into()].span(),
                false,
            ))
                .unwrap();

            self.v_token_for_asset.write((pool, asset), v_token);
            self.asset_for_v_token.write((pool, v_token), asset);

            self.emit(CreateVToken { pool, asset, v_token });
        }
    }

    #[abi(embed_v0)]
    impl PoolFactoryImpl of IPoolFactory<ContractState> {
        /// Returns the class hash of the pool contract
        /// # Returns
        /// * `pool_class_hash` - class hash of the pool contract
        fn pool_class_hash(self: @ContractState) -> felt252 {
            self.pool_class_hash.read()
        }

        /// Returns the class hash of the vToken contract
        /// # Returns
        /// * `v_token_class_hash` - class hash of the vToken contract
        fn v_token_class_hash(self: @ContractState) -> felt252 {
            self.v_token_class_hash.read()
        }

        /// Returns the vToken address for a given collateral asset
        /// # Arguments
        /// * `pool` - address of the pool
        /// * `asset` - address of the asset
        /// # Returns
        /// * `v_token` - address of the vToken contract
        fn v_token_for_asset(self: @ContractState, pool: ContractAddress, asset: ContractAddress) -> ContractAddress {
            self.v_token_for_asset.read((pool, asset))
        }

        /// Returns the collateral asset for a given vToken
        /// # Arguments
        /// * `pool` - address of the pool
        /// * `v_token` - address of the vToken contract
        /// # Returns
        /// * `asset` - address of the collateral asset
        fn asset_for_v_token(self: @ContractState, pool: ContractAddress, v_token: ContractAddress) -> ContractAddress {
            self.asset_for_v_token.read((pool, v_token))
        }

        /// Creates a new pool
        /// # Arguments
        /// * `name` - name of the pool
        /// * `owner` - owner of the pool
        /// * `curator` - curator of the pool
        /// * `oracle` - oracle of the pool
        /// * `fee_recipient` - fee recipient of the pool
        /// * `shutdown_params` - shutdown parameters
        /// * `asset_params` - asset parameters
        /// * `v_token_params` - vToken parameters
        /// * `ltv_params` - loan-to-value parameters
        /// * `interest_rate_params` - interest rate model parameters
        /// * `liquidation_params` - liquidation parameters
        /// * `debt_cap_params` - debt cap parameters
        /// # Returns
        /// * `pool_id` - id of the pool
        fn create_pool(
            ref self: ContractState,
            name: felt252,
            owner: ContractAddress,
            curator: ContractAddress,
            oracle: ContractAddress,
            fee_recipient: ContractAddress,
            shutdown_params: ShutdownParams,
            mut asset_params: Span<AssetParams>,
            mut v_token_params: Span<VTokenParams>,
            mut ltv_params: Span<LTVParams>,
            mut interest_rate_params: Span<InterestRateConfig>,
            mut liquidation_params: Span<LiquidationParams>,
            mut debt_cap_params: Span<DebtCapParams>,
        ) -> ContractAddress {
            // assert that arrays have equal length
            assert!(asset_params.len() > 0, "empty-asset-params");
            assert!(asset_params.len() == interest_rate_params.len(), "interest-rate-params-mismatch");
            assert!(asset_params.len() == v_token_params.len(), "v-token-params-mismatch");

            // deploy the pool
            let (pool_address, _) = (deploy_syscall(
                self.pool_class_hash.read().try_into().unwrap(),
                0,
                array![name.into(), owner.into(), curator.into(), oracle.into()].span(),
                false,
            ))
                .unwrap();

            let pool = IPoolDispatcher { contract_address: pool_address };

            let mut asset_params_copy = asset_params;
            let mut i = 0;
            while !asset_params_copy.is_empty() {
                let asset_params = *asset_params_copy.pop_front().unwrap();
                let asset = asset_params.asset;
                let interest_rate_config = *interest_rate_params.pop_front().unwrap();
                pool.add_asset(asset_params, interest_rate_config);

                let v_token_config = *v_token_params.at(i);
                let VTokenParams { v_token_name, v_token_symbol } = v_token_config;
                self.create_v_token(pool.contract_address, asset, v_token_name, v_token_symbol);

                i += 1;
            }

            // set the liquidation config for each pair
            let mut liquidation_params = liquidation_params;
            while !liquidation_params.is_empty() {
                let params = *liquidation_params.pop_front().unwrap();
                let collateral_asset = *asset_params.at(params.collateral_asset_index).asset;
                let debt_asset = *asset_params.at(params.debt_asset_index).asset;
                pool
                    .set_liquidation_config(
                        collateral_asset,
                        debt_asset,
                        LiquidationConfig { liquidation_factor: params.liquidation_factor },
                    );
            }

            // set the debt caps for each pair
            let mut debt_cap_params = debt_cap_params;
            while !debt_cap_params.is_empty() {
                let params = *debt_cap_params.pop_front().unwrap();
                let collateral_asset = *asset_params.at(params.collateral_asset_index).asset;
                let debt_asset = *asset_params.at(params.debt_asset_index).asset;
                pool.set_debt_cap(collateral_asset, debt_asset, params.debt_cap);
            }

            // set the shutdown config
            let ShutdownParams { recovery_period, subscription_period } = shutdown_params;
            pool.set_shutdown_config(ShutdownConfig { recovery_period, subscription_period });

            // set the fee config
            pool.set_fee_recipient(fee_recipient);

            pool.contract_address
        }
    }
}
