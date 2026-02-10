import { setup } from "../lib";
import { addAssetConfigs } from "../lib/config.sepolia";

const POOL_ADDRESS = "0x6227c13372b8c7b7f38ad1cfe05b5cf515b4e5c596dd05fe8437ab9747b2093";
const ASSETS_TO_ADD = ["STRK"];

try {
  const selected = ASSETS_TO_ADD.map((symbol) => {
    const config = addAssetConfigs[symbol];
    if (!config) throw new Error(`Unknown asset symbol: ${symbol}. Available: ${Object.keys(addAssetConfigs).join(", ")}`);
    return { symbol, ...config };
  });

  const deployer = await setup("sepolia");
  const protocol = await deployer.loadProtocol();

  for (const { symbol, asset, pairs } of selected) {
    console.log(`Adding ${symbol} to oracle...`);
    try {
      await protocol.addAssetsToOracle([asset.pragma_oracle_params]);
    } catch (e: any) {
      if (e.baseError?.data?.execution_error?.error?.includes("oracle-already-set")) {
        console.log(`${symbol} already registered in oracle, skipping...`);
      } else {
        throw e;
      }
    }

    console.log(`Adding ${symbol} to pool...`);
    await protocol.addAssetsToPool(POOL_ADDRESS, [asset]);

    console.log(`Setting ${symbol} lending pairs...`);
    await protocol.addPairsToPool(POOL_ADDRESS, pairs);
  }

  console.log(`\nAssets added successfully: ${ASSETS_TO_ADD.join(", ")}`);
} catch (error: any) {
  console.error("Failed to add assets:");
  if (error.baseError) {
    console.error("Base error:", JSON.stringify(error.baseError, null, 2));
  }
  console.error("Error message:", error.message);
  console.error("Full error:", error);
  process.exit(1);
}
