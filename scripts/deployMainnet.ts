import fs from "fs";
import { setup } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.deployProtocol();
await protocol.addAssetsToOracle(deployer.config.pools["genesis-pool"].params.pragma_oracle_params);
await deployer.setApprovals(protocol.poolFactory, protocol.assets);
await protocol.createPool("genesis-pool");

const deployment = {
  poolFactory: protocol.poolFactory.address,
  pool: protocol.pool?.address || "0x0",
  oracle: protocol.oracle.address,
  assets: protocol.assets.map((asset) => asset.address),
  pragma: {
    oracle: protocol.pragma.oracle.address,
    summary_stats: protocol.pragma.summary_stats.address,
  },
};

fs.writeFileSync(
  // `deployment_${shortString.decodeShortString(await deployer.provider.getChainId()).toLowerCase()}.json`,
  `deployment.json`,
  JSON.stringify(deployment, null, 2),
);
