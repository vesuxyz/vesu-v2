import { Account, CallData, Contract, RpcProvider } from "starknet";
import { BaseDeployer, Protocol, ProtocolConfig, logAddresses, toAddress } from ".";

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
  pools: Contract[];
  oracle: Contract;
  pragma: PragmaContracts;
  assets: Contract[];
}

export class Deployer extends BaseDeployer {
  constructor(
    public provider: RpcProvider,
    account: Account,
    public protocolConfig: ProtocolConfig,
    public owner: Account,
    public lender: Account,
    public borrower: Account,
  ) {
    super(provider, account);
  }

  async loadProtocol(): Promise<Protocol> {
    const addresses = this.protocolConfig.assets!.map((asset) => asset).map(this.loadContract.bind(this));
    const contracts = {
      poolFactory: await this.loadContract(this.protocolConfig.poolFactory!),
      pools: await Promise.all(this.protocolConfig.pools!.map((pool) => this.loadContract(pool))),
      oracle: await this.loadContract(this.protocolConfig.oracle!),
      pragma: {
        oracle: await this.loadContract(this.protocolConfig.pragma.oracle!),
        summary_stats: await this.loadContract(this.protocolConfig.pragma.summary_stats!),
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
    this.protocolConfig.poolFactory = contracts.poolFactory.address;
    this.protocolConfig.oracle = (await this.deferOracle(contracts.poolFactory)).address;
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

  async deferOracle(poolFactory: Contract) {
    poolFactory.connect(this.owner);
    const response = await poolFactory.create_oracle(
      this.owner.address,
      this.protocolConfig.pragma.oracle!,
      this.protocolConfig.pragma.summary_stats!,
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
