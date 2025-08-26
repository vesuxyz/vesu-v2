import { Account, RpcProvider } from "starknet";
import { Deployer, logAddresses } from ".";
import { config as mainnetConfig } from "./config.mainnet";

export async function setup(network: string | undefined) {
  if (process.env.NETWORK != network) throw new Error("NETWORK env var does not match network argument");

  const config = (() => {
    if (network === "mainnet") {
      return mainnetConfig;
    } else {
      throw new Error("Invalid network");
    }
  })();

  const nodeUrl = process.env.RPC_URL || "http://127.0.0.1:5050";
  const isDevnet = !!nodeUrl.match(/localhost|127\.0\.0\.1/);
  console.log("");
  console.log("Config name:", config.name);
  console.log("Provider url:", nodeUrl);

  const provider = new RpcProvider({ nodeUrl });

  const [deployerAccount, accounts] = await loadAccounts(provider, isDevnet);
  logAddresses("Accounts:", { deployer: deployerAccount, ...accounts });

  const { owner, lender, borrower } = accounts;
  return new Deployer(provider, deployerAccount, config, owner, lender, borrower);
}

async function loadAccounts(provider: RpcProvider, isDevnet: boolean) {
  if (isDevnet) {
    const predeployed = await predeployedAccounts(provider);
    const all = predeployed.map(({ address, private_key }) => new Account(provider, address, private_key));
    const [deployer, owner, lender, borrower] = all;
    return [deployer, { owner, lender, borrower }] as const;
  }

  if (!process.env.ADDRESS || !process.env.PRIVATE_KEY) {
    throw new Error("Missing ADDRESS or ACCOUNT_PRIVATE_KEY env var");
  }
  const deployer = new Account(provider, process.env.ADDRESS, process.env.PRIVATE_KEY);
  return [deployer, { owner: deployer, lender: deployer, borrower: deployer }] as const;
}

async function predeployedAccounts(provider: RpcProvider): Promise<Array<{ address: string; private_key: string }>> {
  return handleGet(provider, "predeployed_accounts");
}

async function handleGet(provider: RpcProvider, path: string, args?: string) {
  const origin = provider.channel.nodeUrl.replace("/rpc", "");
  const headers = { "Content-Type": "application/json" };
  const response = await fetch(`${origin}/${path}`, { method: "GET", headers });
  return await response.json();
}
