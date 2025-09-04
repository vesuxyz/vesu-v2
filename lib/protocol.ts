import { Contract } from "starknet";
import { CreatePoolParams, Deployer, Pool, PragmaContracts, PragmaOracleParams, ProtocolContracts, toAddress } from ".";

export class Protocol implements ProtocolContracts {
  constructor(
    public poolFactory: Contract,
    public pool: Contract | undefined,
    public oracle: Contract,
    public pragma: PragmaContracts,
    public assets: Contract[],
    public deployer: Deployer,
  ) {}

  static from(contracts: ProtocolContracts, deployer: Deployer) {
    const { poolFactory, pool, oracle, pragma, assets } = contracts;
    return new Protocol(poolFactory, pool, oracle, pragma, assets, deployer);
  }

  async createPool(name: string, { devnetEnv = false, printParams = false } = {}) {
    let { params } = this.deployer.config.pools[name];
    if (devnetEnv) {
      params = this.patchPoolParamsWithEnv(params);
      if (printParams) {
        console.log("Pool params:");
        console.dir(params, { depth: null });
      }
    }
    return this.createPoolFromParams(params);
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
    this.pool = await this.deployer.loadContract(toAddress(createPoolEvent?.[createPoolSig]?.pool! as BigInt));
    const pool = new Pool(this, params);
    return [pool, response] as const;
  }

  async loadPool(name: string | 0) {
    const { config } = this.deployer;
    if (name === 0) {
      [name] = Object.keys(config.pools);
    }
    const poolConfig = config.pools[name];
    return new Pool(this, poolConfig.params);
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
