import { CairoCustomEnum } from "starknet";
import { Config, EnvAssetParams, SCALE, toScale, toUtilizationScale } from ".";

import CONFIG from "vesu_changelog/configurations/config_genesis_sn_main.json" assert { type: "json" };
import DEPLOYMENT from "vesu_changelog/deployments/deployment_sn_main.json" assert { type: "json" };

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
    singleton: DEPLOYMENT.singletonV2 || "0x0",
    extensionPO: DEPLOYMENT.extensionPOV2 || "0x0",
    pragma: {
      oracle: DEPLOYMENT.pragma.oracle || CONFIG.asset_parameters[0].pragma.oracle || "0x0",
      summary_stats: DEPLOYMENT.pragma.summary_stats || CONFIG.asset_parameters[0].pragma.summary_stats || "0x0",
    },
    ekubo: {
      core: DEPLOYMENT.ekubo.core || "0x0",
    },
  },
  env,
  pools: {
    "genesis-pool": {
      id: 2198503327643286920898110335698706244522220458610657370981979460625005526824n,
      description: "",
      type: "",
      params: {
        pool_name: "Genesis Pool",
        asset_params: CONFIG.asset_parameters.map((asset: any) => ({
          asset: asset.token.address,
          floor: toScale(asset.floor),
          initial_rate_accumulator: SCALE,
          initial_full_utilization_rate: toScale(asset.initial_full_utilization_rate),
          max_utilization: toScale(asset.max_utilization),
          is_legacy: asset.token.is_legacy,
          fee_rate: toScale(asset.fee_rate),
        })),
        ltv_params: CONFIG.pair_parameters.map((pair: any) => {
          const collateral_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.collateral_asset_name,
          );
          const debt_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.debt_asset_name,
          );
          return { collateral_asset_index, debt_asset_index, max_ltv: toScale(pair.max_ltv) };
        }),
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
        liquidation_params: CONFIG.pair_parameters.map((pair: any) => {
          const collateral_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.collateral_asset_name,
          );
          const debt_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.debt_asset_name,
          );
          return { collateral_asset_index, debt_asset_index, liquidation_factor: toScale(pair.liquidation_discount) };
        }),
        debt_caps_params: CONFIG.pair_parameters.map((pair: any) => {
          const collateral_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.collateral_asset_name,
          );
          const debt_asset_index = CONFIG.asset_parameters.findIndex(
            (asset: any) => asset.asset_name === pair.debt_asset_name,
          );
          return { collateral_asset_index, debt_asset_index, debt_cap: toScale(pair.debt_cap) };
        }),
        shutdown_params: {
          recovery_period: BigInt(CONFIG.pool_parameters.recovery_period),
          subscription_period: BigInt(CONFIG.pool_parameters.subscription_period),
          ltv_params: CONFIG.pair_parameters.map((pair: any) => {
            const collateral_asset_index = CONFIG.asset_parameters.findIndex(
              (asset: any) => asset.asset_name === pair.collateral_asset_name,
            );
            const debt_asset_index = CONFIG.asset_parameters.findIndex(
              (asset: any) => asset.asset_name === pair.debt_asset_name,
            );
            return { collateral_asset_index, debt_asset_index, max_ltv: toScale(pair.shutdown_ltv) };
          }),
        },
        fee_params: { fee_recipient: CONFIG.pool_parameters.fee_recipient },
        owner: CONFIG.pool_parameters.owner,
      },
    },
  },
};
