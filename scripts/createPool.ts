import { isEmpty } from "lodash-es";
import { setup } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.loadProtocol();

const pools = Object.keys(deployer.config.pools);
if (isEmpty(pools)) {
  throw new Error("No pools to create in config");
}

for (const name of pools) {
  console.log("Creating pool:", name);

  await protocol.addAssetsToOracle(deployer.config.pools[name].params.pragma_oracle_params);
  await deployer.setApprovals(protocol.poolFactory, protocol.assets);

  const [pool, response] = await protocol.createPool(name);
  console.log("Created tx:", response.transaction_hash);
  console.log("Created pool params:", pool.params);

  console.dir(pool.params, { depth: null });
}
