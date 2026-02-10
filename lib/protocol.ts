import { Contract } from "starknet";
import { AddAssetParams, CreatePoolParams, Deployer, PairConfigParams, PragmaContracts, PragmaOracleParams, ProtocolContracts, toAddress } from ".";

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
    oracle.providerOrAccount = deployer.owner;
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

  async addAssetsToPool(poolAddress: string, params: AddAssetParams[]) {
    const { poolFactory, deployer } = this;
    const pool = await deployer.loadContract(poolAddress);

    for (const param of params) {
      // approve pool factory to transfer inflation fee
      const asset = await deployer.loadContract(param.asset_params.asset);
      asset.providerOrAccount = deployer.owner;
      const approveResponse = await asset.approve(poolFactory.address, 2000);
      await deployer.waitForTransaction(approveResponse.transaction_hash);

      // nominate pool factory as curator so it can add the asset
      pool.providerOrAccount = deployer.owner;
      const nominateResponse = await pool.nominate_curator(poolFactory.address);
      await deployer.waitForTransaction(nominateResponse.transaction_hash);

      // add asset via pool factory
      poolFactory.providerOrAccount = deployer.owner;
      const response = await poolFactory.add_asset(
        poolAddress,
        param.asset_params.asset,
        param.asset_params,
        param.interest_rate_config,
        param.v_token_params,
      );
      await deployer.waitForTransaction(response.transaction_hash);

      // accept curator ownership back
      pool.providerOrAccount = deployer.owner;
      const acceptResponse = await pool.accept_curator_ownership();
      await deployer.waitForTransaction(acceptResponse.transaction_hash);
    }
  }

  async addPairsToPool(poolAddress: string, params: PairConfigParams[]) {
    const { deployer } = this;
    const pool = await deployer.loadContract(poolAddress);
    pool.providerOrAccount = deployer.owner;

    for (const param of params) {
      const response = await pool.set_pair_config(param.collateral_asset, param.debt_asset, {
        max_ltv: param.max_ltv,
        liquidation_factor: param.liquidation_factor,
        debt_cap: param.debt_cap,
      });
      await deployer.waitForTransaction(response.transaction_hash);
    }
  }

  async createPoolFromParams(params: CreatePoolParams) {
    const { poolFactory, oracle, deployer } = this;

    poolFactory.providerOrAccount = deployer.owner;
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
