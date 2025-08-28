import { shortString } from "starknet";
import { setup, toI257 } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.loadProtocol();
const pool = protocol.pool!;
const assets = protocol.assets;
const config = deployer.config.pools["genesis-pool"].params;

console.log("");
console.log("Checking shutdown status for each pair...");

for (const [, asset] of config.pair_params.entries()) {
  let collateral_asset = assets[asset.collateral_asset_index];
  let debt_asset = assets[asset.debt_asset_index];
  const collateral_asset_symbol = shortString.decodeShortString(await collateral_asset.symbol());
  const debt_asset_symbol = shortString.decodeShortString(await debt_asset.symbol());

  console.log("");
  console.log(`  • ${collateral_asset_symbol} / ${debt_asset_symbol}`);

  const context = await pool.context(collateral_asset.address, debt_asset.address, "0x0");

  const collateral_asset_price = Number(context.collateral_asset_price.value) / 1e18;
  const debt_asset_price = Number(context.debt_asset_price.value) / 1e18;

  if (collateral_asset_price === 0 || collateral_asset_price > 150000 || !context.collateral_asset_price.is_valid) {
    console.log("    Invalid price of collateral asset");
    console.log("      price: ", collateral_asset_price, collateral_asset_symbol);
    console.log("      valid: ", context.collateral_asset_price.is_valid);
  }

  if (debt_asset_price === 0 || debt_asset_price > 150000 || !context.debt_asset_price.is_valid) {
    console.log("    Invalid price of debt asset");
    console.log("      price: ", debt_asset_price, debt_asset_symbol);
    console.log("      valid: ", context.debt_asset_price.is_valid);
  }

  const collateral_accumulator = Number(context.collateral_asset_config.last_rate_accumulator) / 1e18;
  const debt_accumulator = Number(context.debt_asset_config.last_rate_accumulator) / 1e18;

  if (collateral_accumulator === 0 || collateral_accumulator > 18) {
    console.log("    Invalid collateral rate_accumulator");
    console.log("      rate_accumulator: ", collateral_accumulator);
  }

  if (debt_accumulator === 0 || debt_accumulator > 18) {
    console.log("    Invalid debt rate_accumulator");
    console.log("      rate_accumulator: ", debt_accumulator);
  }

  const pair = await pool.pairs(collateral_asset.address, debt_asset.address);
  const collateral =
    Number(await pool.calculate_collateral(collateral_asset.address, toI257(pair.total_collateral_shares))) /
    Number(context.collateral_asset_config.scale);
  const debt =
    Number(
      await pool.calculate_debt(
        toI257(pair.total_nominal_debt),
        context.debt_asset_config.last_rate_accumulator,
        context.debt_asset_config.scale,
      ),
    ) / Number(context.debt_asset_config.scale);
  const collateral_value = collateral * collateral_asset_price;
  const debt_value = debt * debt_asset_price;

  const shutdown_status = await pool.shutdown_status(collateral_asset.address, debt_asset.address);

  if (shutdown_status.violating) {
    console.log("    Shutdown status is violating");
    console.log("      shutdown_mode:", shutdown_status.shutdown_mode);
  }

  // const response = await extensionPO.update_shutdown_status(collateral_asset.address, debt_asset.address);
  // await deployer.waitForTransaction(response.transaction_hash);
}
