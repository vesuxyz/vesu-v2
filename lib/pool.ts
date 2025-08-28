import { CreatePoolParams, LiquidatePositionParams, ModifyPositionParams, Protocol, calculateRates } from ".";

type OmitPool<T> = Omit<T, "user">;

export class Pool {
  constructor(
    public protocol: Protocol,
    public params: CreatePoolParams,
  ) {}

  async lend({ collateral_asset, debt_asset, collateral, debt }: OmitPool<ModifyPositionParams>) {
    const { deployer, pool } = this.protocol;
    const params: ModifyPositionParams = {
      collateral_asset,
      debt_asset,
      user: deployer.lender.address,
      collateral,
      debt,
    };
    pool?.connect(deployer.lender);
    const response = await pool?.modify_position(params);
    return response;
  }

  async borrow({ collateral_asset, debt_asset, collateral, debt }: OmitPool<ModifyPositionParams>) {
    const { deployer, pool } = this.protocol;
    const params: ModifyPositionParams = {
      collateral_asset,
      debt_asset,
      user: deployer.borrower.address,
      collateral,
      debt,
    };
    pool?.connect(deployer.borrower);
    const response = await pool?.modify_position(params);
    return response;
  }

  async liquidate({
    collateral_asset,
    debt_asset,
    min_collateral_to_receive,
    debt_to_repay,
  }: OmitPool<LiquidatePositionParams>) {
    const { deployer, pool } = this.protocol;
    const params: LiquidatePositionParams = {
      collateral_asset,
      debt_asset,
      user: deployer.borrower.address,
      min_collateral_to_receive,
      debt_to_repay,
    };
    pool?.connect(deployer.lender);
    const response = await pool?.liquidate_position(params);
    return response;
  }

  async borrowAndSupplyRates(assetAddress: string) {
    const index = this.params.asset_params.findIndex(({ asset }) => asset === assetAddress);
    const config = this.params.interest_rate_configs[index];
    return await calculateRates(this.protocol, assetAddress, config);
  }
}
