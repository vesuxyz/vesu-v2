import { CairoCustomEnum } from "starknet";
import { Config, EnvAssetParams, toScale, toUtilizationScale } from ".";

import CONFIG from "vesu_changelog/configurations/config_genesis_sn_main.json" with { type: "json" };
import DEPLOYMENT from "../deployment.json" with { type: "json" };

const env = CONFIG.asset_parameters.map(
  (asset: any) =>
    new EnvAssetParams(
      asset.asset_name,
      asset.token.symbol,
      BigInt(asset.token.decimals),
      0n,
      asset.pragma.pragma_key,
      0n,
      asset.token.is_legacy,
      toScale(asset.fee_rate),
      asset.token.address,
    ),
);

export const config: Config = {
  name: "mainnet",
  protocol: {
    poolFactory: DEPLOYMENT.poolFactory || "0x0",
    pool: DEPLOYMENT.pool || "0x0",
    oracle: DEPLOYMENT.oracle || "0x0",
    pragma: {
      oracle: DEPLOYMENT.pragma.oracle || CONFIG.asset_parameters[0].pragma.oracle || "0x0",
      summary_stats: DEPLOYMENT.pragma.summary_stats || CONFIG.asset_parameters[0].pragma.summary_stats || "0x0",
    },
  },
  env,
  pools: {
    "genesis-pool": {
      params: {
        name: "genesis-pool",
        owner: CONFIG.pool_parameters.owner,
        curator: CONFIG.pool_parameters.owner,
        fee_recipient: CONFIG.pool_parameters.fee_recipient,
        // oracle: CONFIG.pool_parameters.oracle,
        asset_params: CONFIG.asset_parameters.map((asset: any) => ({
          asset: asset.token.address,
          floor: toScale(asset.floor),
          initial_full_utilization_rate: toScale(asset.initial_full_utilization_rate),
          max_utilization: toScale(asset.max_utilization),
          is_legacy: asset.token.is_legacy,
          fee_rate: toScale(asset.fee_rate),
        })),
        v_token_params: CONFIG.asset_parameters.map((asset: any) => ({
          v_token_name: asset.v_token.v_token_name,
          v_token_symbol: asset.v_token.v_token_symbol,
          debt_asset: CONFIG.asset_parameters.find((_asset: any) => _asset.asset_name !== asset.asset_name)!.token
            .address,
        })),
        interest_rate_configs: CONFIG.asset_parameters.map((asset: any) => ({
          min_target_utilization: toUtilizationScale(asset.min_target_utilization),
          max_target_utilization: toUtilizationScale(asset.max_target_utilization),
          target_utilization: toUtilizationScale(asset.target_utilization),
          min_full_utilization_rate: toScale(asset.min_full_utilization_rate),
          max_full_utilization_rate: toScale(asset.max_full_utilization_rate),
          zero_utilization_rate: toScale(asset.zero_utilization_rate),
          rate_half_life: BigInt(asset.rate_half_life),
          target_rate_percent: toScale(asset.target_rate_percent),
        })),
        pragma_oracle_params: CONFIG.asset_parameters.map((asset: any) => ({
          asset: asset.token.address,
          pragma_key: asset.pragma.pragma_key,
          timeout: BigInt(asset.pragma.timeout),
          number_of_sources: BigInt(asset.pragma.number_of_sources),
          start_time_offset: BigInt(asset.pragma.start_time_offset),
          time_window: BigInt(asset.pragma.time_window),
          aggregation_mode:
            asset.pragma.aggregation_mode == "median" || asset.pragma.aggregation_mode == "Median"
              ? new CairoCustomEnum({ Median: {}, Mean: undefined, Error: undefined })
              : new CairoCustomEnum({ Median: undefined, Mean: {}, Error: undefined }),
        })),
        pair_params: CONFIG.pair_parameters.map((pair: any) => {
          const collateral_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.collateral_asset_name,
          );
          const debt_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.debt_asset_name,
          );
          return {
            collateral_asset_index,
            debt_asset_index,
            max_ltv: toScale(pair.max_ltv),
            liquidation_factor: toScale(pair.liquidation_discount),
            debt_cap: toScale(pair.debt_cap),
          };
        }),
      },
    },
  },
};
