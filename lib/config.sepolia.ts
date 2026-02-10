import { CairoCustomEnum } from "starknet";
import { AddAssetParams, PairConfigParams, PoolConfig, ProtocolConfig, toScale, toUtilizationScale } from ".";

// Sepolia testnet configuration
// Update these addresses after deployment or with existing Sepolia contracts
export const protocolConfig: ProtocolConfig = {
  poolFactory: "0x3ac869e64b1164aaee7f3fd251f86581eab8bfbbd2abdf1e49c773282d4a092",
  pools: ["0x6227c13372b8c7b7f38ad1cfe05b5cf515b4e5c596dd05fe8437ab9747b2093"],
  oracle: "0x6df962cf92b281dfe2a400e241b8f3da07339698add3303f66664f7880ae880",
  pragma: {
    // Pragma Oracle addresses for Sepolia testnet
    oracle: "0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a",
    summary_stats: "0x54563a0537b3ae0ba91032d674a6d468f30a59dc4deb8f0dce4e642b94be15c",
  },
  assets: [
    "0x04861Ba938Aed21f2CD7740acD3765Ac4D2974783A3218367233dE0153490CB6", // WBTC
    "0x0512feAc6339Ff7889822cb5aA2a86C848e9D392bB0E3E237C008674feeD8343", // USDC
  ],
};

// Pool configuration for Sepolia testnet
export const poolConfig: PoolConfig = {
  name: "WBTC Prime Sepolia",
  owner: "0x077D801D970c66b709FFDC4C9baEE0e70F6a4780157A592c6aBA87Ce1d2D14c4",
  curator: "0x077D801D970c66b709FFDC4C9baEE0e70F6a4780157A592c6aBA87Ce1d2D14c4",
  fee_recipient: "0x077D801D970c66b709FFDC4C9baEE0e70F6a4780157A592c6aBA87Ce1d2D14c4",
  asset_params: [
    // WBTC asset parameters (collateral only)
    {
      asset: "0x04861Ba938Aed21f2CD7740acD3765Ac4D2974783A3218367233dE0153490CB6",
      floor: toScale(0.01),
      initial_full_utilization_rate: toScale(0.5),
      max_utilization: toScale(0.95),
      is_legacy: false,
      fee_rate: toScale(0.2),
    },
    // USDC asset parameters (loan asset only)
    {
      asset: "0x0512feAc6339Ff7889822cb5aA2a86C848e9D392bB0E3E237C008674feeD8343",
      floor: toScale(0.01),
      initial_full_utilization_rate: toScale(0.5),
      max_utilization: toScale(0.95),
      is_legacy: false,
      fee_rate: toScale(0.2),
    },
  ],
  v_token_params: [
    {
      v_token_name: "Vesu WBTC" as any,
      v_token_symbol: "vWBTC" as any,
      debt_asset: "0x0512feAc6339Ff7889822cb5aA2a86C848e9D392bB0E3E237C008674feeD8343", // USDC
    },
    {
      v_token_name: "Vesu USDC" as any,
      v_token_symbol: "vUSDC" as any,
      debt_asset: "0x04861Ba938Aed21f2CD7740acD3765Ac4D2974783A3218367233dE0153490CB6", // WBTC
    },
  ],
  interest_rate_configs: [
    // WBTC interest rate config
    {
      min_target_utilization: toUtilizationScale(0.78),
      max_target_utilization: toUtilizationScale(0.82),
      target_utilization: toUtilizationScale(0.8),
      min_full_utilization_rate: BigInt(16075102880), // 50% APY (per-second rate)
      max_full_utilization_rate: BigInt(96450617283), // 300% APY (per-second rate)
      zero_utilization_rate: BigInt(0),
      rate_half_life: BigInt(86400), // 24 hours
      target_rate_percent: toScale(0.2), // 20%
    },
    // USDC interest rate config
    {
      min_target_utilization: toUtilizationScale(0.78),
      max_target_utilization: toUtilizationScale(0.82),
      target_utilization: toUtilizationScale(0.8),
      min_full_utilization_rate: BigInt(16075102880), // 50% APY (per-second rate)
      max_full_utilization_rate: BigInt(96450617283), // 300% APY (per-second rate)
      zero_utilization_rate: BigInt(0),
      rate_half_life: BigInt(86400), // 24 hours
      target_rate_percent: toScale(0.2), // 20%
    },
  ],
  pragma_oracle_params: [
    // WBTC oracle params
    {
      asset: "0x04861Ba938Aed21f2CD7740acD3765Ac4D2974783A3218367233dE0153490CB6",
      pragma_key: "BTC/USD",
      timeout: BigInt(0), // Deactivate sanity checks
      number_of_sources: BigInt(0), // Deactivate sanity checks
      start_time_offset: BigInt(0),
      time_window: BigInt(0),
      aggregation_mode: new CairoCustomEnum({ Median: {}, Mean: undefined, Error: undefined }),
    },
    // USDC oracle params
    {
      asset: "0x0512feAc6339Ff7889822cb5aA2a86C848e9D392bB0E3E237C008674feeD8343",
      pragma_key: "USDC/USD",
      timeout: BigInt(0), // Deactivate sanity checks
      number_of_sources: BigInt(0), // Deactivate sanity checks
      start_time_offset: BigInt(0),
      time_window: BigInt(0),
      aggregation_mode: new CairoCustomEnum({ Median: {}, Mean: undefined, Error: undefined }),
    },
  ],
  pair_params: [
    // Single pair: WBTC collateral, USDC debt
    {
      collateral_asset_index: 0, // WBTC
      debt_asset_index: 1, // USDC
      max_ltv: toScale(0.7), // 70%
      liquidation_factor: toScale(0.9),
      debt_cap: toScale(1000000), // 1M cap
    },
  ],
};

const STRK_ADDRESS = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";
const USDC_ADDRESS = "0x0512feAc6339Ff7889822cb5aA2a86C848e9D392bB0E3E237C008674feeD8343";

export const addAssetConfigs: Record<string, { asset: AddAssetParams; pairs: PairConfigParams[] }> = {
  STRK: {
    asset: {
      asset_params: {
        asset: STRK_ADDRESS,
        floor: toScale(0.01),
        initial_full_utilization_rate: toScale(0.5),
        max_utilization: toScale(0.95),
        is_legacy: false,
        fee_rate: toScale(0.2),
      },
      v_token_params: {
        v_token_name: "Vesu STRK" as any,
        v_token_symbol: "vSTRK" as any,
        debt_asset: USDC_ADDRESS,
      },
      interest_rate_config: {
        min_target_utilization: toUtilizationScale(0.78),
        max_target_utilization: toUtilizationScale(0.82),
        target_utilization: toUtilizationScale(0.8),
        min_full_utilization_rate: BigInt(16075102880), // 50% APY (per-second rate)
        max_full_utilization_rate: BigInt(96450617283), // 300% APY (per-second rate)
        zero_utilization_rate: BigInt(0),
        rate_half_life: BigInt(86400), // 24 hours
        target_rate_percent: toScale(0.2), // 20%
      },
      pragma_oracle_params: {
        asset: STRK_ADDRESS,
        pragma_key: BigInt("6004514686061859652"),
        timeout: BigInt(0),
        number_of_sources: BigInt(0),
        start_time_offset: BigInt(0),
        time_window: BigInt(0),
        aggregation_mode: new CairoCustomEnum({ Median: {}, Mean: undefined, Error: undefined }),
      },
    },
    pairs: [
      {
        collateral_asset: STRK_ADDRESS,
        debt_asset: USDC_ADDRESS,
        max_ltv: toScale(0.5), // 50%
        liquidation_factor: toScale(0.9),
        debt_cap: BigInt(0),
      },
    ],
  },
};
