import { BigNumber } from "bignumber.js";
import { isArray, mapValues } from "lodash-es";
import { BigNumberish, uint256 } from "starknet";
import { CreatePoolParams, i257, u256 } from ".";

export const SCALE = 10n ** 18n;
export const PERCENT = 10n ** 16n;
export const FRACTION = 10n ** 13n;
export const YEAR_IN_SECONDS = 360 * 24 * 60 * 60;

export interface ProtocolConfig {
  poolFactory: string | undefined;
  pools: string[] | undefined;
  oracle: string | undefined;
  pragma: {
    oracle: string | undefined;
    summary_stats: string | undefined;
  };
  assets: string[] | undefined;
}

export interface PoolConfig extends CreatePoolParams {}

export function toU256(x: BigNumberish): u256 {
  return uint256.bnToUint256(x.toString());
}

export function toI257(x: BigNumberish): i257 {
  x = BigInt(x);
  if (x < 0n) {
    return { abs: -x, is_negative: true };
  }
  return { abs: x, is_negative: false };
}

export function logAddresses(label: string, records: Record<string, any>) {
  records = mapValues(records, stringifyAddresses);
  console.log(label, records);
}

function stringifyAddresses(value: any): any {
  if (isArray(value)) {
    return value.map(stringifyAddresses);
  }
  if (value === undefined) {
    return "";
  }
  return value.address ? value.address : value.oracle.address;
}

export function toUtilizationScale(value: number) {
  return BigInt(new BigNumber(value).multipliedBy(Number(100000)).decimalPlaces(0).toFixed());
}

export function toScale(value: number) {
  return BigInt(new BigNumber(value).multipliedBy(Number(SCALE)).decimalPlaces(0).toFixed());
}

export function toAddress(value: BigInt) {
  return ("0x" + value.toString(16)).toLowerCase();
}
