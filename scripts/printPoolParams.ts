import { shortString } from "starknet";
import { setup, toAddress } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.loadProtocol();
const pool = protocol.pool!;
const config = deployer.config.pools["genesis-pool"].params;

console.log("Pool name:                 ", shortString.decodeShortString(await pool.pool_name()));
console.log("Oracle:                    ", toAddress(await pool.oracle()));
console.log("Owner:                     ", toAddress(await pool.owner()));
console.log("Fee recipient:             ", toAddress(await pool.fee_recipient()));
console.log("Curator:                   ", toAddress(await pool.curator()));
console.log("Pending curator:           ", toAddress(await pool.pending_curator()));
console.log("Pausing agent:             ", toAddress(await pool.pausing_agent()));
console.log("Paused:                    ", await pool.is_paused());

for (const [index, asset] of config.asset_params.entries()) {
  const oracle_config = await protocol.oracle.oracle_config(asset.asset);
  console.log("Pragma key:                ", shortString.decodeShortString(oracle_config.pragma_key));
  console.log("Timeout:                   ", Number(oracle_config.timeout) / 60 / 60, "hours");
  console.log("Number of sources:         ", oracle_config.number_of_sources.toString());
  console.log("Start time offset:         ", oracle_config.start_time_offset.toString());
  console.log("Time window:               ", oracle_config.time_window.toString());
  console.log("Aggregation mode:          ", Object.keys(oracle_config.aggregation_mode.variant)[0]
);

  const interest_rate_config = await pool.interest_rate_config(asset.asset);
  console.log("Min target utilization:    ", Number(interest_rate_config.min_target_utilization) / 100_000);
  console.log("Max target utilization:    ", Number(interest_rate_config.max_target_utilization) / 100_000);
  console.log("Target utilization:        ", Number(interest_rate_config.target_utilization) / 100_000);
  console.log("Min full utilization rate: ", Number(interest_rate_config.min_full_utilization_rate) / 1e18);
  console.log("Max full utilization rate: ", Number(interest_rate_config.max_full_utilization_rate) / 1e18);
  console.log("Zero utilization rate:     ", interest_rate_config.zero_utilization_rate.toString());
  console.log("Rate half life:            ", Number(interest_rate_config.rate_half_life) / 60 / 60, "hours");
  console.log("Target rate percent:       ", Number(interest_rate_config.target_rate_percent) / 1e16, "%"); 

  const asset_config = await pool.asset_config(asset.asset);
  let symbol = shortString.decodeShortString(await protocol.assets[index].symbol());
  console.log("Total collateral shares:   ", Number(asset_config.total_collateral_shares) / 1e18);
  console.log("Total nominal debt:        ", Number(asset_config.total_nominal_debt) / 1e18);
  console.log("Reserve:                   ", (asset_config.reserve / asset_config.scale).toString(), symbol);
  console.log("Max utilization:           ", Number(asset_config.max_utilization) / 1e18);
  console.log("Floor:                     ", Number(asset_config.floor) / 1e18, "USD");
  console.log("Scale:                     ", asset_config.scale);
  console.log("Is legacy:                 ", asset_config.is_legacy);
  console.log("Last updated:              ", new Date(Number(asset_config.last_updated) * 1000).toISOString());
  console.log("Last rate accumulator:     ", Number(asset_config.last_rate_accumulator) / 1e18);
  console.log("Last full utilization rate:", Number(asset_config.last_full_utilization_rate) / 1e18);
  console.log("Fee rate:                  ", Number(asset_config.fee_rate) / 1e16, "%");

  console.log("Price:                     ", Number((await pool.price(asset.asset)).value) / 1e18);
  console.log("Rate accumulator:          ", Number((await pool.rate_accumulator(asset.asset))) / 1e18);
  console.log("Utilization:               ", Number((await pool.utilization(asset.asset))) / 1e1);

  console.log("");
}

for (const [, asset] of config.pair_params.entries()) {
  let collateral_asset = protocol.assets[asset.collateral_asset_index];
  let debt_asset = protocol.assets[asset.debt_asset_index];
  const collateral_asset_symbol = shortString.decodeShortString(await collateral_asset.symbol());
  const debt_asset_symbol = shortString.decodeShortString(await debt_asset.symbol());
  let pair_config = await pool.pair_config(collateral_asset.address, debt_asset.address);
  let decimals = await collateral_asset.decimals();

  console.log(`${collateral_asset_symbol} / ${debt_asset_symbol}`);
  console.log("Max LTV:                   ", Number(pair_config.max_ltv) / 1e18);
  console.log("Liquidation factor:        ", Number(pair_config.liquidation_factor) / 1e18);
  console.log("Debt cap:                  ", Number(pair_config.debt_cap) / 10**Number(decimals), debt_asset_symbol);

  console.log("");
}
