use starknet::ContractAddress;
use vesu::data_model::{AssetParams, PairParams, ShutdownParams, VTokenParams};
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
        curator: ContractAddress,
        oracle: ContractAddress,
        fee_recipient: ContractAddress,
        shutdown_params: ShutdownParams,
        asset_params: Span<AssetParams>,
        v_token_params: Span<VTokenParams>,
        interest_rate_params: Span<InterestRateConfig>,
        pair_params: Span<PairParams>,
    ) -> ContractAddress;
    fn add_asset(
        ref self: TContractState,
        pool: ContractAddress,
        asset: ContractAddress,
        asset_params: AssetParams,
        interest_rate_config: InterestRateConfig,
        v_token_params: VTokenParams,
    );
}

#[starknet::contract]
mod PoolFactory {
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::deploy_syscall;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use vesu::data_model::{AssetParams, PairConfig, PairParams, ShutdownConfig, ShutdownParams, VTokenParams};
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::pool_factory::IPoolFactory;
    use vesu::units::INFLATION_FEE;

    #[storage]
    struct Storage {
        pool_class_hash: felt252,
        v_token_class_hash: felt252,
        v_token_for_asset: Map<(ContractAddress, ContractAddress), ContractAddress>,
        asset_for_v_token: Map<(ContractAddress, ContractAddress), ContractAddress>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[derive(Drop, starknet::Event)]
    struct CreateVToken {
        #[key]
        pool: ContractAddress,
        #[key]
        asset: ContractAddress,
        #[key]
        v_token: ContractAddress,
        #[key]
        v_token_name: felt252,
        #[key]
        v_token_symbol: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct CreatePool {
        #[key]
        pool: ContractAddress,
        #[key]
        name: felt252,
        #[key]
        owner: ContractAddress,
        #[key]
        curator: ContractAddress,
        #[key]
        oracle: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct AddAsset {
        #[key]
        pool: ContractAddress,
        #[key]
        asset: ContractAddress,
        #[key]
        name: felt252,
        #[key]
        symbol: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        CreateVToken: CreateVToken,
        CreatePool: CreatePool,
        AddAsset: AddAsset,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState, owner: ContractAddress, pool_class_hash: felt252, v_token_class_hash: felt252,
    ) {
        self.ownable.initializer(owner);
        self.pool_class_hash.write(pool_class_hash);
        self.v_token_class_hash.write(v_token_class_hash);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        /// Adds an asset to the pool. The curator has to nominate the factory as the curator.
        /// The factory will pass the ownership back to the curator after the asset is added.
        /// # Arguments
        /// * `pool` - address of the pool
        /// * `asset` - address of the asset
        /// * `asset_params` - asset parameters
        /// * `interest_rate_config` - interest rate model configuration
        /// * `v_token_params` - vToken parameters
        fn _add_asset(
            ref self: ContractState,
            pool: ContractAddress,
            asset: ContractAddress,
            asset_params: AssetParams,
            interest_rate_config: InterestRateConfig,
            v_token_params: VTokenParams,
        ) {
            let pool = IPoolDispatcher { contract_address: pool };

            // set allowance for the pool to burn inflation fee
            self.transfer_inflation_fee(pool.contract_address, asset, asset_params.is_legacy);

            // add the asset to the pool
            pool.add_asset(asset_params, interest_rate_config);
            self
                .emit(
                    AddAsset {
                        pool: pool.contract_address,
                        asset,
                        name: v_token_params.v_token_name,
                        symbol: v_token_params.v_token_symbol,
                    },
                );

            // create the v token for the asset
            let VTokenParams { v_token_name, v_token_symbol, debt_asset } = v_token_params;
            self.create_v_token(v_token_name, v_token_symbol, pool.contract_address, asset, debt_asset);
        }

        /// Creates a vToken contract for a given collateral asset
        /// # Arguments
        /// * `v_token_name` - name of the vToken
        /// * `v_token_symbol` - symbol of the vToken
        /// * `pool` - Address of the pool
        /// * `asset` - address of the collateral asset
        /// * `debt_asset` - address of the debt asset
        fn create_v_token(
            ref self: ContractState,
            v_token_name: felt252,
            v_token_symbol: felt252,
            pool: ContractAddress,
            asset: ContractAddress,
            debt_asset: ContractAddress,
        ) {
            assert!(self.v_token_for_asset.read((pool, asset)) == Zero::zero(), "v-token-already-created");

            let (v_token, _) = (deploy_syscall(
                self.v_token_class_hash.read().try_into().unwrap(),
                0,
                array![v_token_name, v_token_symbol, pool.into(), asset.into(), debt_asset.into()].span(),
                false,
            ))
                .unwrap();

            self.v_token_for_asset.write((pool, asset), v_token);
            self.asset_for_v_token.write((pool, v_token), asset);

            self.emit(CreateVToken { pool, asset, v_token, v_token_name, v_token_symbol });
        }

        fn transfer_inflation_fee(
            self: @ContractState, pool: ContractAddress, asset: ContractAddress, is_legacy: bool,
        ) {
            let erc20 = IERC20Dispatcher { contract_address: asset };

            if is_legacy {
                assert!(
                    erc20.transferFrom(get_caller_address(), get_contract_address(), INFLATION_FEE),
                    "transferFrom-failed",
                );
            } else {
                assert!(
                    erc20.transfer_from(get_caller_address(), get_contract_address(), INFLATION_FEE),
                    "transfer-from-failed",
                );
            }

            erc20.approve(pool, INFLATION_FEE);
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
        /// * `curator` - curator of the pool
        /// * `oracle` - oracle of the pool
        /// * `fee_recipient` - fee recipient of the pool
        /// * `shutdown_params` - shutdown parameters
        /// * `asset_params` - asset parameters
        /// * `v_token_params` - vToken parameters
        /// * `interest_rate_params` - interest rate model parameters
        /// * `pair_params` - pair parameters
        /// # Returns
        /// * `pool_id` - id of the pool
        fn create_pool(
            ref self: ContractState,
            name: felt252,
            curator: ContractAddress,
            oracle: ContractAddress,
            fee_recipient: ContractAddress,
            shutdown_params: ShutdownParams,
            mut asset_params: Span<AssetParams>,
            mut v_token_params: Span<VTokenParams>,
            mut interest_rate_params: Span<InterestRateConfig>,
            mut pair_params: Span<PairParams>,
        ) -> ContractAddress {
            // assert that arrays have equal length
            assert!(asset_params.len() > 0, "empty-asset-params");
            assert!(asset_params.len() == interest_rate_params.len(), "interest-rate-params-mismatch");
            assert!(asset_params.len() == v_token_params.len(), "v-token-params-mismatch");

            // default owner of all pools is the owner of the pool factory
            let owner = self.ownable.owner();

            // deploy the pool
            let (pool_address, _) = (deploy_syscall(
                self.pool_class_hash.read().try_into().unwrap(),
                0,
                array![name.into(), owner.into(), get_contract_address().into(), oracle.into()].span(),
                false,
            ))
                .unwrap();

            let pool = IPoolDispatcher { contract_address: pool_address };

            self.emit(CreatePool { pool: pool.contract_address, name, owner, curator, oracle });

            let mut asset_params_copy = asset_params;
            let mut i = 0;
            while !asset_params_copy.is_empty() {
                let asset_params = *asset_params_copy.pop_front().unwrap();
                let asset = asset_params.asset;
                self
                    ._add_asset(
                        pool.contract_address,
                        asset,
                        asset_params,
                        *interest_rate_params.pop_front().unwrap(),
                        *v_token_params.at(i),
                    );
                i += 1;
            }

            while !pair_params.is_empty() {
                let params = *pair_params.pop_front().unwrap();
                let collateral_asset = *asset_params.at(params.collateral_asset_index).asset;
                let debt_asset = *asset_params.at(params.debt_asset_index).asset;
                pool
                    .set_pair_config(
                        collateral_asset,
                        debt_asset,
                        PairConfig {
                            max_ltv: params.max_ltv,
                            liquidation_factor: params.liquidation_factor,
                            debt_cap: params.debt_cap,
                        },
                    );
            }

            // set the shutdown config
            let ShutdownParams { recovery_period, subscription_period } = shutdown_params;
            pool.set_shutdown_config(ShutdownConfig { recovery_period, subscription_period });

            // set the fee config
            pool.set_fee_recipient(fee_recipient);

            // nominate the curator
            pool.nominate_curator(curator);

            pool.contract_address
        }

        /// Adds an asset to the pool. The curator has to nominate the factory as the curator.
        /// The factory will pass the ownership back to the curator after the asset is added.
        /// # Arguments
        /// * `pool` - address of the pool
        /// * `asset` - address of the asset
        /// * `asset_params` - asset parameters
        /// * `interest_rate_config` - interest rate model configuration
        /// * `v_token_params` - vToken parameters
        fn add_asset(
            ref self: ContractState,
            pool: ContractAddress,
            asset: ContractAddress,
            asset_params: AssetParams,
            interest_rate_config: InterestRateConfig,
            v_token_params: VTokenParams,
        ) {
            let pool = IPoolDispatcher { contract_address: pool };

            // accept the curator ownership temporarily
            let curator = pool.curator();
            pool.accept_curator_ownership();

            self._add_asset(pool.contract_address, asset, asset_params, interest_rate_config, v_token_params);

            // return the ownership to the curator
            pool.nominate_curator(curator);
        }
    }
}
