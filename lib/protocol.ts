import { Contract } from "starknet";
import { CreatePoolParams, Deployer, PragmaContracts, PragmaOracleParams, ProtocolContracts, toAddress } from ".";

export class Protocol implements ProtocolContracts {
  constructor(
    public poolFactory: Contract,
    public pools: Contract[],
    public oracle: Contract,
    public pragma: PragmaContracts,
    public assets: Contract[],
    public deployer: Deployer,
  ) {}

  static from(contracts: ProtocolContracts, deployer: Deployer) {
    const { poolFactory, pools, oracle, pragma, assets } = contracts;
    return new Protocol(poolFactory, pools, oracle, pragma, assets, deployer);
  }

  async createPool(deployParams: CreatePoolParams, { devnetEnv = false, printParams = false } = {}) {
    if (devnetEnv) {
      deployParams = this.patchPoolParamsWithEnv(deployParams);
      if (printParams) {
        console.log("Pool params:");
        console.dir(deployParams, { depth: null });
      }
    }
    return this.createPoolFromParams(deployParams);
  }

  async addAssetsToOracle(params: PragmaOracleParams[]) {
    const { oracle, deployer } = this;
    oracle.connect(deployer.owner);
    for (const param of params) {
      const response = await oracle.add_asset(param.asset, {
        pragma_key: param.pragma_key,
        timeout: param.timeout,
        number_of_sources: param.number_of_sources,
        start_time_offset: param.start_time_offset,
        time_window: param.time_window,
        aggregation_mode: param.aggregation_mode,
      });
      await deployer.waitForTransaction(response.transaction_hash);
    }
  }

  async createPoolFromParams(params: CreatePoolParams) {
    const { poolFactory, oracle, deployer } = this;

    poolFactory.connect(deployer.owner);
    const response = await poolFactory.create_pool(
      params.name,
      params.curator,
      oracle.address,
      params.fee_recipient,
      params.asset_params,
      params.v_token_params,
      params.interest_rate_configs,
      params.pair_params,
    );
    const receipt = await deployer.waitForTransaction(response.transaction_hash);
    const events = poolFactory.parseEvents(receipt);
    const createPoolSig = "vesu::pool_factory::PoolFactory::CreatePool";
    const createPoolEvent = events.find((event) => event[createPoolSig] != undefined);
    const pool = await this.deployer.loadContract(toAddress(createPoolEvent?.[createPoolSig]?.pool! as BigInt));
    return [pool, response] as const;
  }

  patchPoolParamsWithEnv({ asset_params, owner, ...others }: CreatePoolParams): CreatePoolParams {
    asset_params = asset_params.map(({ asset, ...rest }, index) => ({
      asset: this.assets[index].address,
      ...rest,
    }));
    owner = this.deployer.owner.address;
    return { asset_params, owner, ...others };
  }
}
