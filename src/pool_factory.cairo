use starknet::{ClassHash, ContractAddress};
use vesu::data_model::{AssetParams, PairParams, VTokenParams};
use vesu::interest_rate_model::InterestRateConfig;

#[starknet::interface]
pub trait IPoolFactory<TContractState> {
    fn pool_class_hash(self: @TContractState) -> felt252;
    fn v_token_class_hash(self: @TContractState) -> felt252;
    fn v_token_for_asset(self: @TContractState, pool: ContractAddress, asset: ContractAddress) -> ContractAddress;
    fn asset_for_v_token(self: @TContractState, pool: ContractAddress, v_token: ContractAddress) -> ContractAddress;
    fn update_v_token(ref self: TContractState, pool: ContractAddress, asset: ContractAddress, v_token: ContractAddress);
    fn create_pool(
        ref self: TContractState,
        name: felt252,
        curator: ContractAddress,
        oracle: ContractAddress,
        fee_recipient: ContractAddress,
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
    fn create_oracle(
        ref self: TContractState,
        manager: ContractAddress,
        pragma_oracle: ContractAddress,
        pragma_summary: ContractAddress,
    ) -> ContractAddress;
    fn upgrade_name(self: @TContractState) -> felt252;
    fn upgrade(
        ref self: TContractState,
        new_implementation: ClassHash,
        eic_implementation_data: Option<(ClassHash, Span<felt252>)>,
    );
}

#[starknet::contract]
mod PoolFactory {
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::InternalImpl;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::{deploy_syscall, replace_class_syscall};
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp, get_caller_address, get_contract_address,
    };
    use vesu::data_model::{AssetParams, PairConfig, PairParams, VTokenParams};
    use vesu::interest_rate_model::InterestRateConfig;
    use vesu::pool::{IEICDispatcherTrait, IEICLibraryDispatcher, IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::pool_factory::IPoolFactory;
    use vesu::units::INFLATION_FEE;

    #[storage]
    struct Storage {
        // tracks the pool creation nonce which is incremented after each pool creation
        creation_nonce: u256,
        // the class hash of the pool contract
        pool_class_hash: felt252,
        // the class hash of the vToken contract
        v_token_class_hash: felt252,
        // the class hash of the oracle contract
        oracle_class_hash: felt252,
        // tracks the vToken address for a given asset
        v_token_for_asset: Map<(ContractAddress, ContractAddress), ContractAddress>,
        // tracks the asset address for a given vToken
        asset_for_v_token: Map<(ContractAddress, ContractAddress), ContractAddress>,
        // storage for the ownable component
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
        v_token_name: ByteArray,
        #[key]
        v_token_symbol: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct UpdateVToken {
        #[key]
        pool: ContractAddress,
        #[key]
        asset: ContractAddress,
        #[key]
        prev_v_token: ContractAddress,
        #[key]
        new_v_token: ContractAddress,
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
    }

    #[derive(Drop, starknet::Event)]
    struct CreateOracle {
        #[key]
        oracle: ContractAddress,
        #[key]
        manager: ContractAddress,
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
        CreateVToken: CreateVToken,
        UpdateVToken: UpdateVToken,
        CreatePool: CreatePool,
        AddAsset: AddAsset,
        CreateOracle: CreateOracle,
        ContractUpgraded: ContractUpgraded,
    }

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        pool_class_hash: felt252,
        v_token_class_hash: felt252,
        oracle_class_hash: felt252,
    ) {
        self.ownable.initializer(owner);
        self.pool_class_hash.write(pool_class_hash);
        self.v_token_class_hash.write(v_token_class_hash);
        self.oracle_class_hash.write(oracle_class_hash);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        /// Adds an asset to the pool
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
            self.emit(AddAsset { pool: pool.contract_address, asset });

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
            v_token_name: ByteArray,
            v_token_symbol: ByteArray,
            pool: ContractAddress,
            asset: ContractAddress,
            debt_asset: ContractAddress,
        ) {
            assert!(self.v_token_for_asset.read((pool, asset)) == Zero::zero(), "v-token-already-created");

            let mut calldata = array![];
            v_token_name.serialize(ref calldata);
            v_token_symbol.serialize(ref calldata);
            pool.serialize(ref calldata);
            asset.serialize(ref calldata);
            debt_asset.serialize(ref calldata);
            let (v_token, _) = (deploy_syscall(
                self.v_token_class_hash.read().try_into().unwrap(), 0, calldata.span(), false,
            ))
                .unwrap_syscall();

            self.v_token_for_asset.write((pool, asset), v_token);
            self.asset_for_v_token.write((pool, v_token), asset);

            self.emit(CreateVToken { pool, asset, v_token, v_token_name, v_token_symbol });
        }

        /// Transfers the inflation fee from the caller to the factory and approves the pool to spend the it
        /// # Arguments
        /// * `pool` - address of the pool
        /// * `asset` - address of the asset
        /// * `is_legacy` - whether the asset is a legacy ERC20 (only supporting camelCase instead of snake_case)
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

        /// Updates the vToken address for a given collateral asset
        /// # Arguments
        /// * `pool` - address of the pool
        /// * `asset` - address of the collateral asset
        /// * `v_token` - address of the new vToken contract
        fn update_v_token(ref self: ContractState, pool: ContractAddress, asset: ContractAddress, v_token: ContractAddress) {
            let curator = IPoolDispatcher { contract_address: pool }.curator();
            assert!(curator == get_caller_address(), "caller-not-curator");

            let prev_v_token = self.v_token_for_asset.read((pool, asset));
            self.v_token_for_asset.write((pool, asset), v_token);
            self.asset_for_v_token.write((pool, v_token), asset);
            
            self.emit(UpdateVToken { pool, asset, prev_v_token, new_v_token: v_token });
        }

        /// Creates a new pool
        /// # Arguments
        /// * `name` - name of the pool
        /// * `curator` - curator of the pool
        /// * `oracle` - oracle of the pool
        /// * `fee_recipient` - fee recipient of the pool
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

            // compute the salt to derive a unique pool address
            let nonce = self.creation_nonce.read() + 1;
            self.creation_nonce.write(nonce);
            let salt: Array<felt252> = array![nonce.try_into().unwrap(), get_block_timestamp().into()];

            // deploy the pool
            let (pool_address, _) = (deploy_syscall(
                self.pool_class_hash.read().try_into().unwrap(),
                poseidon_hash_span(salt.span()),
                array![name.into(), owner.into(), get_contract_address().into(), oracle.into()].span(),
                false,
            ))
                .unwrap_syscall();

            let pool = IPoolDispatcher { contract_address: pool_address };

            self.emit(CreatePool { pool: pool.contract_address, name, owner, curator, oracle });

            // add assets to the pool and deploy the corresponding v token
            let mut i = 0;
            let mut asset_params_copy = asset_params;
            while !asset_params_copy.is_empty() {
                let params = *asset_params_copy.pop_front().unwrap();
                self
                    ._add_asset(
                        pool.contract_address,
                        params.asset,
                        params,
                        *interest_rate_params.pop_front().unwrap(),
                        v_token_params.at(i).clone(),
                    );
                i += 1;
            }

            // set the pair configurations
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
            assert!(curator == get_caller_address(), "caller-not-curator");
            pool.accept_curator_ownership();

            self._add_asset(pool.contract_address, asset, asset_params, interest_rate_config, v_token_params);

            // return the ownership to the curator
            pool.nominate_curator(curator);
        }

        /// Creates a new oracle contract
        /// # Arguments
        /// * `manager` - manager of the oracle
        /// * `pragma_oracle` - address of the pragma oracle contract
        /// * `pragma_summary` - address of the pragma summary contract
        /// # Returns
        /// * `oracle` - address of the oracle contract
        fn create_oracle(
            ref self: ContractState,
            manager: ContractAddress,
            pragma_oracle: ContractAddress,
            pragma_summary: ContractAddress,
        ) -> ContractAddress {
            // default owner of all oracles is the owner of the pool factory
            let owner = self.ownable.owner();

            let (oracle, _) = (deploy_syscall(
                self.oracle_class_hash.read().try_into().unwrap(),
                0,
                array![owner.into(), manager.into(), pragma_oracle.into(), pragma_summary.into()].span(),
                false,
            ))
                .unwrap_syscall();

            self.emit(CreateOracle { oracle, manager });

            oracle
        }

        /// Returns the name of the contract
        /// # Returns
        /// * `name` - the name of the contract
        fn upgrade_name(self: @ContractState) -> felt252 {
            'Vesu Pool Factory'
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
