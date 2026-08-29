import { Account, RpcProvider } from "starknet";
import { Deployer, ProtocolConfig, logAddresses } from ".";

export async function setup(network: string | undefined) {
  if (process.env.NETWORK != network) throw new Error("NETWORK env var does not match network argument");

  const nodeUrl = process.env.RPC_URL || "http://127.0.0.1:5050";
  console.log("");
  console.log("Provider url:", nodeUrl);
  console.log("Network:", network);

  const provider = new RpcProvider({ nodeUrl });

  const [deployerAccount, accounts] = await loadAccounts(provider);
  logAddresses("Accounts:", { deployer: deployerAccount, ...accounts });

  // Load network-specific configuration
  const protocolConfig = await loadNetworkConfig(network);

  const { owner, lender, borrower } = accounts;
  return new Deployer(provider, deployerAccount, protocolConfig, owner, lender, borrower);
}

async function loadNetworkConfig(network: string | undefined): Promise<ProtocolConfig> {
  if (network === "sepolia") {
    const { protocolConfig } = await import("./config.sepolia.js");
    return protocolConfig;
  } else if (network === "mainnet") {
    const { protocolConfig } = await import("./config.mainnet.js");
    return protocolConfig;
  } else {
    throw new Error(`Unsupported network: ${network}. Use 'mainnet' or 'sepolia'`);
  }
}

async function loadAccounts(provider: RpcProvider) {
  if (!process.env.ADDRESS || !process.env.PRIVATE_KEY) {
    throw new Error("Missing ADDRESS or ACCOUNT_PRIVATE_KEY env var");
  }
  const deployer = new Account({ provider, address: process.env.ADDRESS, signer: process.env.PRIVATE_KEY });
  return [deployer, { owner: deployer, lender: deployer, borrower: deployer }] as const;
}
