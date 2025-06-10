use starknet::{ContractAddress};

#[derive(PartialEq, Copy, Drop, Serde, starknet::Store)]
struct OracleConfigV0 {
    pragma_key: felt252,
    timeout: u64,
    number_of_sources: u32
}

#[starknet::interface]
trait IDefaultExtensionPOV0<TContractState> {
    fn oracle_config(ref self: TContractState, pool_id: felt252, asset: ContractAddress) -> OracleConfigV0;
}

#[starknet::interface]
trait IMigrationExtension<TContractState> {
    fn owner(self: @TContractState) -> ContractAddress;
    fn singleton_v1(self: @TContractState) -> ContractAddress;
    fn singleton_v2(self: @TContractState) -> ContractAddress;
    fn old_extension(self: @TContractState, pool_id: felt252) -> ContractAddress;
    fn set_owner(ref self: TContractState, owner: ContractAddress);
    fn set_singleton_v2_migrator(ref self: TContractState, migrator: ContractAddress);
    fn set_extension_v2_migrator(ref self: TContractState, migrator: ContractAddress, extension_v2: ContractAddress);
    fn set_contracts(ref self: TContractState, singleton_v1: ContractAddress, singleton_v2: ContractAddress);
    fn set_pool_owner_v1(
        ref self: TContractState, pool_id: felt252, extension_v1: ContractAddress, owner: ContractAddress
    );
    fn set_pool_owner_v2(
        ref self: TContractState, pool_id: felt252, extension_v2: ContractAddress, owner: ContractAddress
    );
    fn reset_extension(ref self: TContractState, pool_id: felt252, extension: ContractAddress);
    fn migrate_init(ref self: TContractState, pool_id: felt252);
    fn migrate_pool(
        ref self: TContractState,
        pool_id: felt252,
        extension_v2: ContractAddress,
        creator: ContractAddress,
        assets: Span<ContractAddress>,
        pairs: Span<(ContractAddress, ContractAddress)>
    );
    fn migrate_pool_extension(
        ref self: TContractState,
        pool_id: felt252,
        extension_v2: ContractAddress,
        assets: Span<ContractAddress>,
        pairs: Span<(ContractAddress, ContractAddress)>
    );
    fn migrate_extension_positions(
        ref self: TContractState, pool_id: felt252, extension_v2: ContractAddress, assets: Span<ContractAddress>
    );
    fn migrate_position(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        from: ContractAddress,
        to: ContractAddress
    );
    fn migrate_funds(ref self: TContractState, pool_id: felt252, assets: Span<ContractAddress>, amount: u256);
    fn migrate_unlock(ref self: TContractState);
}

#[starknet::contract]
mod MigrationExtension {
    use alexandria_math::i257::{i257, i257_new};
    use starknet::{
        ContractAddress, get_contract_address, get_caller_address, event::EventEmitter, contract_address_const
    };
    use vesu::{
        map_list::{map_list_component, map_list_component::MapListTrait},
        data_model::{
            Amount, UnsignedAmount, AssetParams, AssetPrice, LTVParams, Context, LTVConfig, ModifyPositionParams,
            AmountDenomination, AmountType, DebtCapParams, AssetConfig
        },
        singleton::{ISingletonDispatcher, ISingletonDispatcherTrait},
        vendor::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait}, units::INFLATION_FEE,
        extension::{
            default_extension_po::{
                IDefaultExtensionDispatcher, IDefaultExtensionDispatcherTrait, LiquidationParams, ShutdownParams,
                PragmaOracleParams, ITimestampManagerCallback, IDefaultExtension, FeeParams, VTokenParams,
                IDefaultExtensionCallback, ITokenizationCallback
            },
            interface::{IExtension, IExtensionDispatcher, IExtensionDispatcherTrait},
            components::{
                interest_rate_model::{
                    InterestRateConfig, interest_rate_model_component,
                    interest_rate_model_component::InterestRateModelTrait
                },
                position_hooks::{
                    position_hooks_component, position_hooks_component::PositionHooksTrait, ShutdownStatus,
                    ShutdownMode, ShutdownConfig, LiquidationConfig, Pair
                },
                pragma_oracle::{pragma_oracle_component, pragma_oracle_component::PragmaOracleTrait, OracleConfig},
                fee_model::{fee_model_component, fee_model_component::FeeModelTrait, FeeConfig},
                tokenization::{tokenization_component, tokenization_component::TokenizationTrait}
            }
        },
        v2::{
            singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait},
            default_extension_po_v2::{IDefaultExtensionPOV2Dispatcher, IDefaultExtensionPOV2DispatcherTrait},
            migration_extension::{
                IMigrationExtension, IMigrationExtensionDispatcher, IMigrationExtensionDispatcherTrait,
                IDefaultExtensionPOV0Dispatcher, IDefaultExtensionPOV0DispatcherTrait, OracleConfigV0
            }
        }
    };

    #[storage]
    struct Storage {
        owner: ContractAddress,
        singleton_v1: ContractAddress,
        singleton_v2: ContractAddress,
        old_extensions: LegacyMap::<felt252, ContractAddress>,
        revert_on_rate_accumulator: bool
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl MigrationExtensionImpl of IMigrationExtension<ContractState> {
        fn owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn singleton_v1(self: @ContractState) -> ContractAddress {
            self.singleton_v1.read()
        }

        fn singleton_v2(self: @ContractState) -> ContractAddress {
            self.singleton_v2.read()
        }

        fn old_extension(self: @ContractState, pool_id: felt252) -> ContractAddress {
            self.old_extensions.read(pool_id)
        }

        fn set_owner(ref self: ContractState, owner: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            self.owner.write(owner);
        }

        fn set_singleton_v2_migrator(ref self: ContractState, migrator: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let singleton_v2 = ISingletonV2Dispatcher { contract_address: self.singleton_v2.read() };
            singleton_v2.set_migrator(migrator);
        }

        fn set_extension_v2_migrator(
            ref self: ContractState, migrator: ContractAddress, extension_v2: ContractAddress
        ) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let extension_v2 = IDefaultExtensionPOV2Dispatcher { contract_address: extension_v2 };
            extension_v2.set_migrator(migrator);
        }

        fn set_contracts(ref self: ContractState, singleton_v1: ContractAddress, singleton_v2: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            self.singleton_v1.write(singleton_v1);
            self.singleton_v2.write(singleton_v2);
        }

        fn set_pool_owner_v1(
            ref self: ContractState, pool_id: felt252, extension_v1: ContractAddress, owner: ContractAddress
        ) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let extension_v1 = IDefaultExtensionDispatcher { contract_address: extension_v1 };
            extension_v1.set_pool_owner(pool_id, owner);
        }

        fn set_pool_owner_v2(
            ref self: ContractState, pool_id: felt252, extension_v2: ContractAddress, owner: ContractAddress
        ) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let extension_v2 = IDefaultExtensionPOV2Dispatcher { contract_address: extension_v2 };
            extension_v2.set_pool_owner(pool_id, owner);
        }

        fn reset_extension(ref self: ContractState, pool_id: felt252, extension: ContractAddress) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let singleton_v1 = ISingletonDispatcher { contract_address: self.singleton_v1.read() };
            singleton_v1.set_extension(pool_id, extension);
        }

        fn migrate_init(ref self: ContractState, pool_id: felt252) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let singleton_v1 = ISingletonDispatcher { contract_address: self.singleton_v1.read() };
            let extension = IDefaultExtensionDispatcher { contract_address: singleton_v1.extension(pool_id) };
            if singleton_v1.extension(pool_id) != get_contract_address() {
                self.old_extensions.write(pool_id, extension.contract_address);
                extension.set_extension(pool_id, get_contract_address());
            }
            self.revert_on_rate_accumulator.write(true);
        }

        fn migrate_pool(
            ref self: ContractState,
            pool_id: felt252,
            extension_v2: ContractAddress,
            creator: ContractAddress,
            assets: Span<ContractAddress>,
            pairs: Span<(ContractAddress, ContractAddress)>,
        ) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let singleton_v1 = ISingletonDispatcher { contract_address: self.singleton_v1.read() };
            let singleton_v2 = ISingletonV2Dispatcher { contract_address: self.singleton_v2.read() };

            self.revert_on_rate_accumulator.write(false);

            let mut asset_configs: Array<(ContractAddress, AssetConfig)> = array![];
            let mut assets = assets;
            while !assets
                .is_empty() {
                    let asset = *assets.pop_front().unwrap();
                    let (asset_config, _) = singleton_v1.asset_config(pool_id, asset);
                    asset_configs.append((asset, asset_config));
                };

            let mut ltv_configs: Array<(ContractAddress, ContractAddress, LTVConfig)> = array![];
            let mut pairs = pairs;
            while !pairs
                .is_empty() {
                    let (collateral_asset, debt_asset) = *pairs.pop_front().unwrap();
                    let ltv_config = singleton_v1.ltv_config(pool_id, collateral_asset, debt_asset);
                    ltv_configs.append((collateral_asset, debt_asset, ltv_config));
                };

            singleton_v2.migrate_pool(pool_id, extension_v2, creator, asset_configs.span(), ltv_configs.span());

            self.revert_on_rate_accumulator.write(true);
        }

        fn migrate_pool_extension(
            ref self: ContractState,
            pool_id: felt252,
            extension_v2: ContractAddress,
            assets: Span<ContractAddress>,
            pairs: Span<(ContractAddress, ContractAddress)>,
        ) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");

            self.revert_on_rate_accumulator.write(false);

            let extension_v1 = IDefaultExtensionDispatcher { contract_address: self.old_extensions.read(pool_id) };
            let extension_v2 = IDefaultExtensionPOV2Dispatcher { contract_address: extension_v2 };

            let name = if pool_id != 0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28 {
                extension_v1.pool_name(pool_id)
            } else {
                'Genesis'
            };

            let mut v_token_configs: Array<(felt252, felt252, ContractAddress, ContractAddress)> = array![];
            let mut interest_rate_configs: Array<(ContractAddress, InterestRateConfig)> = array![];
            let mut oracle_configs: Array<(ContractAddress, OracleConfig)> = array![];

            let mut assets = assets;
            while !assets
                .is_empty() {
                    let asset = *assets.pop_front().unwrap();
                    let v_token_v1 = extension_v1.v_token_for_collateral_asset(pool_id, asset);
                    let name = IERC20Dispatcher { contract_address: v_token_v1 }.name();
                    let symbol = IERC20Dispatcher { contract_address: v_token_v1 }.symbol();
                    v_token_configs.append((name, symbol, asset, v_token_v1));
                    interest_rate_configs.append((asset, extension_v1.interest_rate_config(pool_id, asset)));
                    if pool_id != 0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28 {
                        oracle_configs.append((asset, extension_v1.oracle_config(pool_id, asset)));
                    } else {
                        let oracle_config = IDefaultExtensionPOV0Dispatcher {
                            contract_address: extension_v1.contract_address
                        }
                            .oracle_config(pool_id, asset);
                        oracle_configs
                            .append(
                                (
                                    asset,
                                    OracleConfig {
                                        pragma_key: oracle_config.pragma_key,
                                        timeout: oracle_config.timeout,
                                        number_of_sources: oracle_config.number_of_sources,
                                        start_time_offset: 0,
                                        time_window: 0,
                                        aggregation_mode: Default::default()
                                    }
                                )
                            );
                    }
                };

            let mut liquidation_configs: Array<(ContractAddress, ContractAddress, LiquidationConfig)> = array![];
            let mut shutdown_ltv_configs: Array<(ContractAddress, ContractAddress, LTVConfig)> = array![];
            let mut shutdown_ltv_pairs: Array<(ContractAddress, ContractAddress, Pair)> = array![];
            let mut debt_caps: Array<(ContractAddress, ContractAddress, u256)> = array![];

            let mut pairs = pairs;
            while !pairs
                .is_empty() {
                    let (collateral_asset, debt_asset) = *pairs.pop_front().unwrap();
                    liquidation_configs
                        .append(
                            (
                                collateral_asset,
                                debt_asset,
                                extension_v1.liquidation_config(pool_id, collateral_asset, debt_asset)
                            )
                        );
                    shutdown_ltv_configs
                        .append(
                            (
                                collateral_asset,
                                debt_asset,
                                extension_v1.shutdown_ltv_config(pool_id, collateral_asset, debt_asset)
                            )
                        );
                    shutdown_ltv_pairs
                        .append(
                            (collateral_asset, debt_asset, extension_v1.pairs(pool_id, collateral_asset, debt_asset))
                        );
                    debt_caps
                        .append(
                            (
                                collateral_asset,
                                debt_asset,
                                if pool_id != 0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28 {
                                    extension_v1.debt_caps(pool_id, collateral_asset, debt_asset)
                                } else {
                                    100000000000000000000000000
                                }
                            )
                        );
                };

            let shutdown_config = extension_v1.shutdown_config(pool_id);
            let fee_config = extension_v1.fee_config(pool_id);

            extension_v2
                .migrate_pool(
                    pool_id,
                    name,
                    v_token_configs.span(),
                    interest_rate_configs.span(),
                    oracle_configs.span(),
                    liquidation_configs.span(),
                    shutdown_ltv_pairs.span(),
                    debt_caps.span(),
                    shutdown_ltv_configs.span(),
                    shutdown_config,
                    fee_config,
                    self.owner.read()
                );

            self.revert_on_rate_accumulator.write(true);
        }

        fn migrate_extension_positions(
            ref self: ContractState, pool_id: felt252, extension_v2: ContractAddress, assets: Span<ContractAddress>
        ) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            let extension_v1 = self.old_extensions.read(pool_id);
            let mut assets = assets;
            while !assets
                .is_empty() {
                    let asset = *assets.pop_front().unwrap();
                    self.migrate_position(pool_id, asset, Zeroable::zero(), extension_v1, extension_v2);
                    self.migrate_position(pool_id, asset, Zeroable::zero(), extension_v2, extension_v2);
                };
        }

        fn migrate_position(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            from: ContractAddress,
            to: ContractAddress,
        ) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            self.revert_on_rate_accumulator.write(false);
            let singleton_v2 = ISingletonV2Dispatcher { contract_address: self.singleton_v2.read() };
            singleton_v2.migrate_position(pool_id, collateral_asset, debt_asset, from, to);
            self.revert_on_rate_accumulator.write(true);
        }

        fn migrate_funds(ref self: ContractState, pool_id: felt252, assets: Span<ContractAddress>, amount: u256) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");

            self.revert_on_rate_accumulator.write(false);

            let singleton_v1 = ISingletonDispatcher { contract_address: self.singleton_v1.read() };
            let singleton_v2 = ISingletonV2Dispatcher { contract_address: self.singleton_v2.read() };

            let mut assets = assets;
            while !assets
                .is_empty() {
                    let asset = *assets.pop_front().unwrap();
                    let (asset_config, _) = singleton_v1.asset_config(pool_id, asset);
                    singleton_v1
                        .retrieve_from_reserve(
                            pool_id,
                            asset,
                            singleton_v2.contract_address,
                            if amount == 0 {
                                asset_config.reserve
                            } else {
                                amount
                            }
                        );
                };

            self.revert_on_rate_accumulator.write(true);
        }

        fn migrate_unlock(ref self: ContractState) {
            assert!(self.owner.read() == get_caller_address(), "caller-not-owner");
            self.revert_on_rate_accumulator.write(false);
        }
    }

    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        fn singleton(self: @ContractState) -> ContractAddress {
            self.singleton_v1.read()
        }

        fn price(self: @ContractState, pool_id: felt252, asset: ContractAddress) -> AssetPrice {
            let extension = IExtensionDispatcher { contract_address: self.old_extensions.read(pool_id) };
            extension.price(pool_id, asset)
        }

        fn interest_rate(
            self: @ContractState,
            pool_id: felt252,
            asset: ContractAddress,
            utilization: u256,
            last_updated: u64,
            last_full_utilization_rate: u256,
        ) -> u256 {
            let extension = IExtensionDispatcher { contract_address: self.old_extensions.read(pool_id) };
            extension.interest_rate(pool_id, asset, utilization, last_updated, last_full_utilization_rate)
        }

        fn rate_accumulator(
            self: @ContractState,
            pool_id: felt252,
            asset: ContractAddress,
            utilization: u256,
            last_updated: u64,
            last_rate_accumulator: u256,
            last_full_utilization_rate: u256,
        ) -> (u256, u256) {
            if self.revert_on_rate_accumulator.read() {
                assert!(false, "revert-on-rate-accumulator");
            }
            (last_rate_accumulator, last_full_utilization_rate)
        }

        fn before_modify_position(
            ref self: ContractState,
            context: Context,
            collateral: Amount,
            debt: Amount,
            data: Span<felt252>,
            caller: ContractAddress
        ) -> (Amount, Amount) {
            assert!(false, "not-allowed");
            (Default::default(), Default::default())
        }

        fn after_modify_position(
            ref self: ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            data: Span<felt252>,
            caller: ContractAddress
        ) -> bool {
            assert!(false, "not-allowed");
            false
        }

        fn before_transfer_position(
            ref self: ContractState,
            from_context: Context,
            to_context: Context,
            collateral: UnsignedAmount,
            debt: UnsignedAmount,
            data: Span<felt252>,
            caller: ContractAddress
        ) -> (UnsignedAmount, UnsignedAmount) {
            assert!(false, "not-allowed");
            (Default::default(), Default::default())
        }

        fn after_transfer_position(
            ref self: ContractState,
            from_context: Context,
            to_context: Context,
            collateral_delta: u256,
            collateral_shares_delta: u256,
            debt_delta: u256,
            nominal_debt_delta: u256,
            data: Span<felt252>,
            caller: ContractAddress
        ) -> bool {
            assert!(false, "not-allowed");
            false
        }

        fn before_liquidate_position(
            ref self: ContractState, context: Context, data: Span<felt252>, caller: ContractAddress
        ) -> (u256, u256, u256) {
            assert!(false, "not-allowed");
            (0, 0, 0)
        }

        fn after_liquidate_position(
            ref self: ContractState,
            context: Context,
            collateral_delta: i257,
            collateral_shares_delta: i257,
            debt_delta: i257,
            nominal_debt_delta: i257,
            bad_debt: u256,
            data: Span<felt252>,
            caller: ContractAddress
        ) -> bool {
            assert!(false, "not-allowed");
            false
        }
    }
}
