import { publicEnv } from "@/lib/env";

/**
 * Mirrors `contracts/sources/config.move` exactly - see docs/spec/units.md.
 * There is no runtime check that these stay in sync with the deployed
 * package; changing a value here (or in Move) without changing both is a
 * silent-corruption bug, not a compile error.
 */
export const MODULE_ADDRESS = publicEnv.NEXT_PUBLIC_MODULE_ADDRESS;

/** `<module>::<name>` for every Move function this app calls. */
export function moveFunction(module: string, name: string) {
  return `${MODULE_ADDRESS}::${module}::${name}` as const;
}

/**
 * Oracle/series feed ids are plain UTF-8 strings like `"BTC/USD"` encoded as
 * `vector<u8>` (Pyth's binary feed ids are gone along with Pyth itself - see
 * the oracle note in docs/architecture.md). This is the one place that
 * encoding happens, so every caller building a `series`/`oracle` payload
 * produces byte-identical ids.
 */
export function encodeFeedId(symbol: string): Uint8Array {
  return new TextEncoder().encode(symbol);
}

/**
 * Inverse of `encodeFeedId`, for decoding a feed id read back from a view
 * call. View calls return `vector<u8>` as a `0x`-prefixed hex string
 * (verified against the deployed package: `get_series` returns
 * `"0x4254432f555344"` for the `"BTC/USD"` feed registered on testnet).
 */
export function decodeFeedId(hex: string): string {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return new TextDecoder().decode(bytes);
}

/** 1 unit of USD price = `PRICE_UNIT` (6 decimals), e.g. $65,000.00 = 65_000_000000n. */
export const PRICE_UNIT = 1_000_000n;

/** Size is stored in lots; 1 lot = 0.0001 of the underlying. */
export const LOT_UNIT = 10_000n;

export const COLLATERAL_DECIMALS = 6;

export const BPS_DENOMINATOR = 10_000n;
export const MAX_LEVERAGE = 10;
export const INITIAL_MARGIN_BPS = 1_000n;
export const MAINTENANCE_MARGIN_BPS = 500n;
export const LIQUIDATION_PENALTY_BPS = 100n;

export const SETTLEMENT_BATCH_MAX = 25;
export const SERIES_DURATION_SECONDS = 86_400;
export const MAX_FILLS_PER_ORDER = 10;
export const MAX_OPEN_ORDERS_PER_SERIES = 20;
export const ORACLE_MAX_PRICE_AGE_SECONDS = 90;

/** `margin::side_long()` / `margin::side_short()`. */
export const Side = {
  Long: 0,
  Short: 1,
} as const;
export type Side = (typeof Side)[keyof typeof Side];

/** `position::status_*()`. */
export const PositionStatus = {
  Open: 0,
  Closed: 1,
  Liquidated: 2,
  Settled: 3,
} as const;
export type PositionStatus = (typeof PositionStatus)[keyof typeof PositionStatus];

/** `position::reason_*()` - why a `PositionUpdated` event fired. */
export const PositionUpdateReason = {
  Fill: 0,
  AddMargin: 1,
  Liquidation: 2,
  Settlement: 3,
} as const;
export type PositionUpdateReason = (typeof PositionUpdateReason)[keyof typeof PositionUpdateReason];

/** `order_book::order_status_*()`. */
export const OrderStatus = {
  Open: 0,
  Partial: 1,
  Filled: 2,
  Cancelled: 3,
} as const;
export type OrderStatus = (typeof OrderStatus)[keyof typeof OrderStatus];

/** `orders::tif_gtc()` / `orders::tif_ioc()`. */
export const TimeInForce = {
  Gtc: 0,
  Ioc: 1,
} as const;
export type TimeInForce = (typeof TimeInForce)[keyof typeof TimeInForce];
