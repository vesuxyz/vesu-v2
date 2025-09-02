import assert from "assert";
import { unzip } from "lodash-es";
import { Account, Call, CallData, Contract, RpcProvider } from "starknet";
import { BaseDeployer, Config, Protocol, logAddresses, toAddress } from ".";

export interface PragmaConfig {
  oracle: string | undefined;
  summary_stats: string | undefined;
}

export interface PragmaContracts {
  oracle: Contract;
  summary_stats: Contract;
}

export interface ProtocolContracts {
  poolFactory: Contract;
  pool: Contract | undefined;
  oracle: Contract;
  pragma: PragmaContracts;
  assets: Contract[];
}

export class Deployer extends BaseDeployer {
  constructor(
    public provider: RpcProvider,
    account: Account,
    public config: Config,
    public owner: Account,
    public lender: Account,
    public borrower: Account,
  ) {
    super(provider, account);
  }

  async deployEnvAndProtocol(): Promise<Protocol> {
    assert(this.config.env, "Test environment not defined, use loadProtocol for existing networks");
    const [envContracts, envCalls] = await this.deferEnv();
    const [protocolContracts, protocolCalls] = await this.deferProtocol();
    let response = await this.execute([...envCalls, ...protocolCalls]);
    await this.waitForTransaction(response.transaction_hash);
    const oracle = await this.deferOracle(protocolContracts.poolFactory);
    const contracts = { ...protocolContracts, oracle, ...envContracts, pool: undefined };
    await this.setApprovals(contracts.poolFactory, contracts.assets);
    logAddresses("Deployed:", contracts);
    return Protocol.from(contracts, this);
  }

  async loadProtocol(): Promise<Protocol> {
    const { protocol, pools } = this.config;
    const addresses = Object.values(pools)
      .flatMap(({ params }) => params.asset_params.map(({ asset }) => asset))
      .map(this.loadContract.bind(this));
    console.log(protocol);
    const contracts = {
      poolFactory: await this.loadContract(protocol.poolFactory!),
      pool: await this.loadContract(protocol.pool!),
      oracle: await this.loadContract(protocol.oracle!),
      pragma: {
        oracle: await this.loadContract(protocol.pragma.oracle!),
        summary_stats: await this.loadContract(protocol.pragma.summary_stats!),
      },
      assets: await Promise.all(addresses),
    };
    logAddresses("Loaded:", contracts);
    return Protocol.from(contracts, this);
  }

  async deployProtocol() {
    const [contracts, calls] = await this.deferProtocol();
    let response = await this.execute([...calls]);
    await this.waitForTransaction(response.transaction_hash);
    this.config.protocol.poolFactory = contracts.poolFactory.address;
    this.config.protocol.oracle = (await this.deferOracle(contracts.poolFactory)).address;
    return await this.loadProtocol();
  }

  async deferProtocol() {
    const [poolFactory, poolFactoryCalls] = await this.deferContract(
      "PoolFactory",
      CallData.compile({
        owner: this.owner.address,
        pool_class_hash: await this.declareCached("Pool"),
        v_token_class_hash: await this.declareCached("VToken"),
        oracle_class_hash: await this.declareCached("Oracle"),
      }),
    );

    return [{ poolFactory }, [...poolFactoryCalls]] as const;
  }

  async deployEnv() {
    const [contracts, calls] = await this.deferEnv();
    const response = await this.execute([...calls]);
    await this.waitForTransaction(response.transaction_hash);
    return [contracts, response] as const;
  }

  async deferEnv() {
    const [assets, assetCalls] = await this.deferMockAssets(this.lender.address);
    const [pragma_oracle, summary_stats, pragmaOracleCalls] = await this.deferPragmaOracle();
    return [
      { assets, pragma: { oracle: pragma_oracle, summary_stats } },
      [...assetCalls, ...pragmaOracleCalls],
    ] as const;
  }

  async deferMockAssets(recipient: string) {
    // first asset declared separately to avoid out of memory on CI
    const [first, ...rest] = this.config.env!;

    const calldata = CallData.compile({ ...first.erc20Params(), recipient });
    const [asset0, calls0] = await this.deferContract("MockAsset", calldata);
    const promises = rest.map((params) =>
      this.deferContract("MockAsset", CallData.compile({ ...params.erc20Params(), recipient })),
    );
    const [otherAssets, otherCalls] = unzip(await Promise.all(promises));

    const assets = [asset0, ...otherAssets] as Contract[];
    const calls = [...calls0, ...otherCalls.flat()] as Call[];
    return [assets, calls] as const;
  }

  async deferPragmaOracle() {
    const [pragma, pragmaCalls] = await this.deferContract("MockPragmaOracle");
    const [summary_stats, summaryStatsCalls] = await this.deferContract("MockPragmaSummary");
    const setupCalls = this.config.env!.map(({ pragmaKey, price }) =>
      pragma.populateTransaction.set_price(pragmaKey, price),
    );
    return [pragma, summary_stats, [...pragmaCalls, ...summaryStatsCalls, ...setupCalls]] as const;
  }

  async deferOracle(poolFactory: Contract) {
    poolFactory.connect(this.owner);
    const response = await poolFactory.create_oracle(
      this.owner.address,
      this.config.protocol.pragma.oracle!,
      this.config.protocol.pragma.summary_stats!,
    );
    const receipt = await this.waitForTransaction(response.transaction_hash);
    const events = poolFactory.parseEvents(receipt);
    const createOracleSig = "vesu::pool_factory::PoolFactory::CreateOracle";
    const createOracleEvent = events.find((event) => event[createOracleSig] != undefined);
    return await this.loadContract(toAddress(createOracleEvent?.[createOracleSig]?.oracle! as BigInt));
  }

  async setApprovals(contract: Contract, assets: Contract[]) {
    const approvalCalls = await Promise.all(
      assets.map(async (asset, index) => {
        console.log(await asset.balanceOf(this.owner.address));
        return asset.populateTransaction.approve(contract.address, 2000);
      }),
    );
    let response = await this.owner.execute(approvalCalls);
    await this.waitForTransaction(response.transaction_hash);
  }
}
