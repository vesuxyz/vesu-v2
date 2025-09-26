import { isEmpty } from "lodash-es";
import { setup } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.loadProtocol();

if (isEmpty(Object.keys(deployer.config.pool))) {
  throw new Error("No Pool Config provided");
}

console.log("Creating pool:", deployer.config.pool.deployParams.name);

await protocol.addAssetsToOracle(deployer.config.pool.deployParams.pragma_oracle_params);
await deployer.setApprovals(protocol.poolFactory, protocol.assets);

const [pool, response] = await protocol.createPool();
console.log("Created tx:", response.transaction_hash);

console.dir(pool.params, { depth: null });
