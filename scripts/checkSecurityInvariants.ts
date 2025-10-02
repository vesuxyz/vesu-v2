import { Contract, shortString } from "starknet";
import { setup } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.loadProtocol();
const pools = protocol.pools;
const assets = protocol.assets!;
const pairs = assets.flatMap((a) => assets.filter((b) => b !== a).map((b) => [a, b]));

console.log("");
console.log("Checking oracle status for each pair...");

async function getNameAndSymbol(asset: Contract) {
  let name = await asset.name();
  let symbol = await asset.symbol();
  try {
    name = shortString.decodeShortString(name);
    symbol = shortString.decodeShortString(symbol);
  } catch (error) {}
  return { name, symbol };
}

for (const pool of pools) {
  console.log("Checking pool:", shortString.decodeShortString(await pool.pool_name()));

  await Promise.all(
    pairs.map(async ([collateral_asset, debt_asset]) => {
      let context;
      try {
        context = await pool.context(collateral_asset.address, debt_asset.address, "0x0");
      } catch (error) {
        return;
      }
      if (context.collateral_asset_config.scale === 0) return;

      const [{ symbol: collateral_asset_symbol }, { symbol: debt_asset_symbol }, pair_config, decimals] =
        await Promise.all([
          getNameAndSymbol(collateral_asset),
          getNameAndSymbol(debt_asset),
          pool.pair_config(collateral_asset.address, debt_asset.address),
          collateral_asset.decimals(),
        ]);

      if (pair_config.max_ltv > 0 || pair_config.liquidation_factor > 0 || pair_config.debt_cap > 0) {
        console.log(`${collateral_asset_symbol} / ${debt_asset_symbol}`);
        const collateral_asset_price = Number(context.collateral_asset_price.value) / 1e18;
        const debt_asset_price = Number(context.debt_asset_price.value) / 1e18;

        if (
          collateral_asset_price === 0 ||
          collateral_asset_price > 150000 ||
          !context.collateral_asset_price.is_valid
        ) {
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
      }
    }),
  );

  console.log("");
}
