use starknet::ContractAddress;
#[starknet::interface]
pub trait IMintable<TContractState> {
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
}
#[starknet::contract]
mod MockAsset {
    use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use vesu::test::mock_asset::IMintable;
    use vesu::vendor::erc20::IERC20Metadata;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        initial_supply: u256,
        recipient: ContractAddress,
    ) {
        self.decimals.write(decimals);
        self.erc20.mint(recipient, initial_supply);
    }

    #[abi(embed_v0)]
    impl ERC20Metadata of IERC20Metadata<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }
    }

    #[abi(embed_v0)]
    impl MintableImpl of IMintable<ContractState> {
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.decimals.read();
            self.erc20.mint(recipient, amount);
            true
        }
    }
}
