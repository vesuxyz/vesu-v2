import fs from "fs";
import { poolConfig, setup } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.deployProtocol();
await protocol.addAssetsToOracle(poolConfig.pragma_oracle_params);
await deployer.setApprovals(protocol.poolFactory, protocol.assets);
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

fs.writeFileSync(`deployment.json`, JSON.stringify(deployment, null, 2));
