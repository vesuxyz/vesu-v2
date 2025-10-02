import { Account, RpcProvider } from "starknet";
import { Deployer, logAddresses } from ".";
import { protocolConfig } from "./config.mainnet";

export async function setup(network: string | undefined) {
  if (process.env.NETWORK != network) throw new Error("NETWORK env var does not match network argument");

  const nodeUrl = process.env.RPC_URL || "http://127.0.0.1:5050";
  console.log("");
  console.log("Provider url:", nodeUrl);

  const provider = new RpcProvider({ nodeUrl });

  const [deployerAccount, accounts] = await loadAccounts(provider);
  logAddresses("Accounts:", { deployer: deployerAccount, ...accounts });

  const { owner, lender, borrower } = accounts;
  return new Deployer(provider, deployerAccount, protocolConfig, owner, lender, borrower);
}

async function loadAccounts(provider: RpcProvider) {
  if (!process.env.ADDRESS || !process.env.PRIVATE_KEY) {
    throw new Error("Missing ADDRESS or ACCOUNT_PRIVATE_KEY env var");
  }
  const deployer = new Account(provider, process.env.ADDRESS, process.env.PRIVATE_KEY);
  return [deployer, { owner: deployer, lender: deployer, borrower: deployer }] as const;
}
