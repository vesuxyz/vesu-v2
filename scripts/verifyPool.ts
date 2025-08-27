import { assert } from "console";
import { shortString } from "starknet";
import { setup, toAddress } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.loadProtocol();
const pool = protocol.pool!;
const config = deployer.config.pools["genesis-pool"].params;

assert(toAddress(await pool.oracle()) === deployer.config.protocol.oracle!.toLowerCase(), "oracle-neq");
assert((await pool.owner()) === BigInt(deployer.owner.address), "owner-neq");
assert(BigInt(await pool.fee_recipient()) === BigInt(config.fee_recipient!.toLowerCase()), "fee_recipient-neq");
const shutdown_config = await pool.shutdown_config();
assert(shutdown_config.recovery_period === config.shutdown_params.recovery_period, "recovery_period-neq");
assert(shutdown_config.subscription_period === config.shutdown_params.subscription_period, "subscription_period-neq");

for (const [index, asset] of config.asset_params.entries()) {
  const oracle_config = await protocol.oracle.oracle_config(asset.asset);
  assert(
    shortString.decodeShortString(oracle_config.pragma_key) === config.pragma_oracle_params[index].pragma_key,
    "pragma_key-neq",
  );
  assert(oracle_config.timeout === config.pragma_oracle_params[index].timeout, "timeout-neq");
  assert(
    oracle_config.number_of_sources === config.pragma_oracle_params[index].number_of_sources,
    "number_of_sources-neq",
  );
  // assert(
  //   oracle_config.start_time_offset === pool.params.pragma_oracle_params[index].start_time_offset,
  //   "start_time_offset-neq",
  // );
  // assert(oracle_config.time_window === pool.params.pragma_oracle_params[index].time_window, "time_window-neq");
  // assert(
  //   JSON.stringify(oracle_config.aggregation_mode) ===
  //     JSON.stringify(pool.params.pragma_oracle_params[index].aggregation_mode),
  //   "aggregation_mode-neq",
  // );

  const interest_rate_config = await pool.interest_rate_config(asset.asset);
  assert(
    interest_rate_config.min_target_utilization === config.interest_rate_configs[index].min_target_utilization,
    "min_target_utilization-neq",
  );
  assert(
    interest_rate_config.max_target_utilization === config.interest_rate_configs[index].max_target_utilization,
    "max_target_utilization-neq",
  );
  assert(
    interest_rate_config.target_utilization === config.interest_rate_configs[index].target_utilization,
    "target_utilization-neq",
  );
  assert(
    interest_rate_config.min_full_utilization_rate === config.interest_rate_configs[index].min_full_utilization_rate,
    "min_full_utilization_rate-neq",
  );
  assert(
    interest_rate_config.max_full_utilization_rate === config.interest_rate_configs[index].max_full_utilization_rate,
    "max_full_utilization_rate-neq",
  );
  assert(
    interest_rate_config.zero_utilization_rate === config.interest_rate_configs[index].zero_utilization_rate,
    "zero_utilization_rate-neq",
  );
  assert(
    interest_rate_config.rate_half_life === config.interest_rate_configs[index].rate_half_life,
    "rate_half_life-neq",
  );
  assert(
    interest_rate_config.target_rate_percent === config.interest_rate_configs[index].target_rate_percent,
    "target_rate_percent-neq",
  );

  const asset_config = await pool.asset_config(asset.asset);
  assert(asset_config.total_collateral_shares >= 0n, "total_collateral_shares-neq");
  assert(asset_config.total_nominal_debt >= 0n, "total_nominal_debt-neq");
  assert(asset_config.reserve >= 0n, "reserve-neq");
  assert(asset_config.max_utilization === config.asset_params[index].max_utilization, "max_utilization-neq");
  assert(asset_config.floor === config.asset_params[index].floor, "floor-neq");
  assert(asset_config.scale > 0n, "scale-neq");
  assert(asset_config.is_legacy === false, "is_legacy-neq");
  assert(asset_config.last_updated > 0n, "last_updated-neq");
  assert(asset_config.last_rate_accumulator > 0n, "last_rate_accumulator-neq");
  assert(asset_config.last_full_utilization_rate > 0n, "last_full_utilization_rate-neq");
  assert(asset_config.fee_rate === config.asset_params[index].fee_rate, "fee_rate-neq");

  // assert((await pool.price(asset.asset)).value > 0n, "price-neq");
  assert((await pool.rate_accumulator(asset.asset)) > 0n, "rate_accumulator-neq");
  assert((await pool.utilization(asset.asset)) === 0n, "utilization-neq");
}

for (const [, asset] of config.ltv_params.entries()) {
  let collateral_asset = config.asset_params[asset.collateral_asset_index];
  let debt_asset = config.asset_params[asset.debt_asset_index];
  let ltv_config = await pool.ltv_config(collateral_asset.asset, debt_asset.asset);
  console.log(collateral_asset.asset, debt_asset.asset, ltv_config, asset.max_ltv);
  assert(ltv_config.max_ltv === asset.max_ltv, "max_ltv-neq");
}

for (const [, asset] of config.liquidation_params.entries()) {
  let collateral_asset = config.asset_params[asset.collateral_asset_index];
  let debt_asset = config.asset_params[asset.debt_asset_index];
  let liquidation_config = await pool.liquidation_config(collateral_asset.asset, debt_asset.asset);
  assert(liquidation_config.liquidation_factor === asset.liquidation_factor, "liquidation_factor-neq");
}

for (const [, asset] of config.debt_caps_params.entries()) {
  let collateral_asset = config.asset_params[asset.collateral_asset_index];
  let debt_asset = config.asset_params[asset.debt_asset_index];
  assert(
    (await pool.debt_caps(collateral_asset.asset, debt_asset.asset)) === asset.debt_cap,
    "debt_cap-neq",
  );
}
