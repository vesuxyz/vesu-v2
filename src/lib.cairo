mod common;
mod data_model;

mod math;
mod packing;
mod singleton;
mod units;

mod v_token;

mod extension {
    mod default_extension_cl;
    mod default_extension_ek;
    mod default_extension_po;
    mod interface;
    mod components {
        mod chainlink_oracle;
        mod ekubo_oracle;
        mod fee_model;
        mod interest_rate_model;
        mod position_hooks;
        mod pragma_oracle;
        mod tokenization;
    }
}

mod v2 {
    mod default_extension_po_v2;
    mod singleton_v2;
    mod v_token_v2;
}

mod vendor {
    mod chainlink;
    mod ekubo;
    mod erc20;
    mod erc20_component;
    mod ownable;
    mod pragma;
}

mod test {
    mod mock_asset;
    mod mock_chainlink_aggregator;
    mod mock_ekubo_core;
    mod mock_ekubo_oracle;
    mod mock_extension;
    mod mock_oracle;
    mod mock_singleton;
    mod setup;
    mod test_asset_retrieval;
    mod test_common;
    mod test_default_extension_cl;
    mod test_default_extension_ek;
    mod test_default_extension_po;
    mod test_ekubo_oracle;
    mod test_flash_loan;
    mod test_forking;
    mod test_interest_rate_model;
    mod test_liquidate_position;
    mod test_math;
    mod test_modify_position;
    mod test_packing;
    mod test_pool_donations;
    mod test_pragma_oracle;
    mod test_reentrancy;
    mod test_shutdown;
    mod test_singleton;
    mod test_transfer_position;
    mod test_v_token;
    mod v2 {
        mod mock_singleton_upgrade;
        mod setup_v2;
        mod test_asset_retrieval_v2;
        mod test_default_extension_po_v2;
        mod test_flash_loan_v2;
        mod test_forking_v2;
        mod test_liquidate_position_v2;
        mod test_modify_position_v2;
        mod test_pool_donations_v2;
        mod test_reentrancy_v2;
        mod test_shutdown_v2;
        mod test_singleton_v2;
        mod test_transfer_position_v2;
        mod test_v_token_v2;
    }
}
