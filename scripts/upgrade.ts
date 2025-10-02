import { CairoOption, CairoOptionVariant } from "starknet";
import { setup } from "../lib";

const deployer = await setup("mainnet");
const protocol = await deployer.loadProtocol();
const { poolFactory, pools } = protocol;

const poolFactoryClassHash = await deployer.declareCached("PoolFactory");
const poolClassHash = await deployer.declareCached("Pool");
const vTokenClassHash = await deployer.declareCached("VToken");
const oracleClassHash = await deployer.declareCached("Oracle");

console.log("PoolFactory class hash:", poolFactoryClassHash);
console.log("Pool class hash:", poolClassHash);
console.log("VToken class hash:", vTokenClassHash);
console.log("Oracle class hash:", oracleClassHash);

poolFactory.connect(deployer.owner);
let response = await poolFactory.upgrade(poolFactoryClassHash, new CairoOption(CairoOptionVariant.None));
await deployer.waitForTransaction(response.transaction_hash);
response = await poolFactory.set_pool_class_hash(poolClassHash);
await deployer.waitForTransaction(response.transaction_hash);
response = await poolFactory.set_v_token_class_hash(vTokenClassHash);
await deployer.waitForTransaction(response.transaction_hash);
response = await poolFactory.set_oracle_class_hash(oracleClassHash);
await deployer.waitForTransaction(response.transaction_hash);

for (const pool of pools) {
  pool.connect(deployer.owner);
  const response = await pool.upgrade(poolClassHash, new CairoOption(CairoOptionVariant.None));
  await deployer.waitForTransaction(response.transaction_hash);
}
