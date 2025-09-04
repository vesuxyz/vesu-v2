import { BigNumberish, CairoCustomEnum, Uint256 } from "starknet";
import { toI257 } from ".";

export type u256 = Uint256;

export interface i257 {
  abs: bigint;
  is_negative: boolean;
}

interface Amount {
  amount_type: CairoCustomEnum;
  denomination: CairoCustomEnum;
  value: i257;
}

interface UnsignedAmount {
  amount_type: CairoCustomEnum;
  denomination: CairoCustomEnum;
  value: bigint;
}

export interface AssetParams {
  asset: string;
  floor: bigint;
  initial_full_utilization_rate: bigint;
  max_utilization: bigint;
  is_legacy: boolean;
  fee_rate: bigint;
}

export interface PragmaOracleParams {
  asset: string;
  pragma_key: BigNumberish;
  timeout: bigint;
  number_of_sources: bigint;
  start_time_offset: bigint;
  time_window: bigint;
  aggregation_mode: CairoCustomEnum;
}

export interface InterestRateConfig {
  min_target_utilization: bigint;
  max_target_utilization: bigint;
  target_utilization: bigint;
  min_full_utilization_rate: bigint;
  max_full_utilization_rate: bigint;
  zero_utilization_rate: bigint;
  rate_half_life: bigint;
  target_rate_percent: bigint;
}

export interface AssetIndexes {
  collateral_asset_index: number;
  debt_asset_index: number;
}

export interface PairParams extends AssetIndexes {
  max_ltv: bigint;
  liquidation_factor: bigint;
  debt_cap: bigint;
}

export interface AssetConfig {
  total_collateral_shares: bigint;
  total_nominal_debt: bigint;
  reserve: bigint;
  max_utilization: bigint;
  floor: bigint;
  scale: bigint;
  is_legacy: boolean;
  last_updated: bigint;
  last_rate_accumulator: bigint;
  last_full_utilization_rate: bigint;
  fee_rate: bigint;
}

export interface FeeParams {
  fee_recipient: string;
}

export interface VTokenParams {
  v_token_name: string;
  v_token_symbol: string;
}

export interface CreatePoolParams {
  name: string;
  owner: string;
  curator: string;
  // oracle: string;
  fee_recipient: string;
  asset_params: AssetParams[];
  v_token_params: VTokenParams[];
  interest_rate_configs: InterestRateConfig[];
  pragma_oracle_params: PragmaOracleParams[];
  pair_params: PairParams[];
}

export interface ModifyPositionParams {
  collateral_asset: string;
  debt_asset: string;
  user: string;
  collateral: Amount;
  debt: Amount;
}

export interface TransferPositionParams {
  from_collateral_asset: string;
  to_collateral_asset: string;
  from_debt_asset: string;
  to_debt_asset: string;
  from_user: string;
  to_user: string;
  collateral: UnsignedAmount;
  debt: UnsignedAmount;
  from_data: any;
  to_data: any;
}

export interface LiquidatePositionParams {
  collateral_asset: string;
  debt_asset: string;
  user: string;
  min_collateral_to_receive: bigint;
  debt_to_repay: bigint;
}

export function Amount(args?: {
  amountType: "Delta" | "Target";
  denomination: "Native" | "Assets";
  value: bigint;
}): Amount {
  if (!args) {
    return {
      amount_type: new CairoCustomEnum({ Delta: {}, Target: undefined }),
      denomination: new CairoCustomEnum({ Native: {}, Assets: undefined }),
      value: toI257(0n),
    };
  }

  const amountTypeEnum: Record<string, any> = { Delta: undefined, Target: undefined };
  amountTypeEnum[args.amountType] = {};

  const denominationEnum: Record<string, any> = { Native: undefined, Assets: undefined };
  denominationEnum[args.denomination] = {};

  return {
    amount_type: new CairoCustomEnum(amountTypeEnum),
    denomination: new CairoCustomEnum(denominationEnum),
    value: toI257(args.value),
  };
}

export function UnsignedAmount(args?: {
  amountType: "Delta" | "Target";
  denomination: "Native" | "Assets";
  value: bigint;
}): UnsignedAmount {
  if (!args) {
    return {
      amount_type: new CairoCustomEnum({ Delta: {}, Target: undefined }),
      denomination: new CairoCustomEnum({ Native: {}, Assets: undefined }),
      value: 0n,
    };
  }

  const amountTypeEnum: Record<string, any> = { Delta: undefined, Target: undefined };
  amountTypeEnum[args.amountType] = {};

  const denominationEnum: Record<string, any> = { Native: undefined, Assets: undefined };
  denominationEnum[args.denomination] = {};

  return {
    amount_type: new CairoCustomEnum(amountTypeEnum),
    denomination: new CairoCustomEnum(denominationEnum),
    value: args.value,
  };
}
