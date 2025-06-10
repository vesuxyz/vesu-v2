import { setup } from "../lib";

const deployer = await setup(process.env.NETWORK);

const [extensionPO] = await deployer.deployExtensions(
  deployer.config.protocol.singleton!,
  deployer.config.protocol.pragma,
);

console.log("ExtensionPO: ", extensionPO.address);
