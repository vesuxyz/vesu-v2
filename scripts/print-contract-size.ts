import { readFileSync } from "fs";
import { json } from "starknet";

const contractsFolder = "./target/release/vesu_";

function getContractSize(contractName: string): number {
  const compiledContract = json.parse(
    readFileSync(`${contractsFolder}${contractName}.compiled_contract_class.json`).toString("ascii"),
  );
  return compiledContract.bytecode.length;
}
// Max contract bytecode size at https://docs.starknet.io/chain-info/
console.log(`MAX SIZE:      81290`);
console.log(`DefaultExtensionPOV2:  ${getContractSize("DefaultExtensionPOV2")}`);
console.log(`SingletonV2:  ${getContractSize("SingletonV2")}`);
