import { MODULE_ADDRESS } from "@/lib/chain/constants";

/**
 * Mirrors the event structs in contracts/sources/events.move and
 * docs/spec/events.md exactly - every field here is the Move event body
 * only. `tx_version`/`event_index` are indexer metadata that wraps *any*
 * event, not part of the event body itself, so they live in `lib/sync`'s
 * mapper types instead of here.
 *
 * u64 and address fields come back from the Indexer/fullnode as strings (to
 * avoid JS number precision loss on u64), not numbers. `vector<u8>` fields
 * come back hex-encoded.
 */
export type Deposited = {
  trader: string;
  amount: string;
};

export type Withdrawn = {
  trader: string;
  amount: string;
};

export type SeriesCreated = {
  series_id: string;
  underlying: string;
  pyth_feed_id: string;
  expiry_ts: string;
};

export type PositionUpdated = {
  series_id: string;
  trader: string;
  side: number;
  size: string;
  entry_price: string;
  margin: string;
  realized_pnl_is_negative: boolean;
  realized_pnl_magnitude: string;
  reason: number;
};

export type OrderPlaced = {
  order_id: string;
  series_id: string;
  trader: string;
  side: number;
  price: string;
  size: string;
  remaining: string;
  tif: number;
  reduce_only: boolean;
};

export type OrderUpdated = {
  order_id: string;
  remaining: string;
  status: number;
};

export type TradeExecuted = {
  series_id: string;
  price: string;
  size: string;
  maker: string;
  taker: string;
  taker_side: number;
};

export type Liquidated = {
  trader: string;
  series_id: string;
  price: string;
  penalty: string;
};

export type EventName =
  | "Deposited"
  | "Withdrawn"
  | "SeriesCreated"
  | "PositionUpdated"
  | "OrderPlaced"
  | "OrderUpdated"
  | "TradeExecuted"
  | "Liquidated";

export type EventDataByName = {
  Deposited: Deposited;
  Withdrawn: Withdrawn;
  SeriesCreated: SeriesCreated;
  PositionUpdated: PositionUpdated;
  OrderPlaced: OrderPlaced;
  OrderUpdated: OrderUpdated;
  TradeExecuted: TradeExecuted;
  Liquidated: Liquidated;
};

/** The fully-qualified Move type of an event, for filtering Indexer queries. */
export function eventTypeTag<N extends EventName>(name: N): string {
  return `${MODULE_ADDRESS}::events::${name}`;
}
