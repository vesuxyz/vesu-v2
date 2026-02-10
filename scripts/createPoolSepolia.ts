import { poolConfig, setup } from "../lib";

const deployer = await setup("sepolia");
const protocol = await deployer.loadProtocol();

console.log("Creating pool:");

await protocol.addAssetsToOracle(poolConfig.pragma_oracle_params);
await deployer.setApprovals(protocol.poolFactory, protocol.assets);

const [pool, response] = await protocol.createPool(poolConfig);
console.log("Created tx:", response.transaction_hash);

console.log("Accepting curator ownership...");
pool.providerOrAccount = deployer.owner;
const acceptResponse = await pool.accept_curator_ownership();
await deployer.waitForTransaction(acceptResponse.transaction_hash);
console.log("Curator ownership accepted");

console.dir(pool.params, { depth: null });