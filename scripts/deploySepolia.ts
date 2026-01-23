import fs from "fs";
import { setup } from "../lib";
import { poolConfig } from "../lib/config.sepolia";

try {
  const deployer = await setup("sepolia");
  console.log("Deploying protocol...");
  const protocol = await deployer.deployProtocol();
  console.log("Protocol deployed, adding assets to oracle...");
  await protocol.addAssetsToOracle(poolConfig.pragma_oracle_params);
  console.log("Setting approvals...");
  await deployer.setApprovals(protocol.poolFactory, protocol.assets);
  console.log("Creating pool...");
  const [pool] = await protocol.createPool(poolConfig);

  const deployment = {
    poolFactory: protocol.poolFactory.address,
    pools: [pool.address],
    oracle: protocol.oracle.address,
    assets: protocol.assets.map((asset) => asset.address),
    pragma: {
      oracle: protocol.pragma.oracle.address,
      summary_stats: protocol.pragma.summary_stats.address,
    },
  };

  fs.writeFileSync(`deployment-sepolia.json`, JSON.stringify(deployment, null, 2));
  console.log("\nDeployment saved to deployment-sepolia.json");
} catch (error: any) {
  console.error("Deployment failed:");
  if (error.baseError) {
    console.error("Base error:", JSON.stringify(error.baseError, null, 2));
  }
  console.error("Error message:", error.message);
  console.error("Full error:", error);
  process.exit(1);
}