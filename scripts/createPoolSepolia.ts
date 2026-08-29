import { poolConfig, setup } from "../lib";

const deployer = await setup("sepolia");
const protocol = await deployer.loadProtocol();

console.log("Creating pool:");

await protocol.addAssetsToOracle(poolConfig.pragma_oracle_params);
await deployer.setApprovals(protocol.poolFactory, protocol.assets);

const [pool, response] = await protocol.createPool(poolConfig);
console.log("Created tx:", response.transaction_hash);

console.dir(pool.params, { depth: null });