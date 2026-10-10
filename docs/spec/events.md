# Event Contract

All events are emitted from `contracts/sources/events.move` and consumed by `src/lib/sync/mappers`.
**Every event carries a post-state snapshot** (the resulting balance/position/order state, not a
delta), so the indexer never recomputes PnL or margin — it only copies fields into Postgres. This
is what keeps the DB a pure derived cache.

| Event | Emitted by | Fields (post-state snapshot) | Mapped to table |
|---|---|---|---|
| `SeriesCreated` | `series::create_series`, `series::roll_series` | series_id, underlying, pyth_feed_id, expiry_ts | `series` |
| `SeriesSettled` | `settlement::settle_positions` (first call) | series_id, settlement_price, settled_at | `series` |
| `OrderPlaced` | `orders::place_order` | order_id, series_id, trader, side, price, size, remaining, tif, reduce_only | `orders` |
| `OrderUpdated` | `orders::place_order` (on fill), `orders::cancel_order` | order_id, remaining, status | `orders` |
| `TradeExecuted` | `matching` (per fill) | tx_version, event_index, series_id, price, size, maker, taker, taker_side | `trades` |
| `PositionUpdated` | `clearing::apply_fill`, `clearing::add_margin`, `liquidation::liquidate`, `settlement::settle_positions` | series_id, trader, side, size, entry_price, margin, realized_pnl, reason | `positions` |
| `Deposited` | `vault::deposit` | trader, amount | `account_events` (kind=`deposit`) |
| `Withdrawn` | `vault::withdraw` | trader, amount | `account_events` (kind=`withdraw`) |
| `Liquidated` | `liquidation::liquidate` | trader, series_id, price, penalty | `account_events` (kind=`liquidation`) + `PositionUpdated` |

`reason` on `PositionUpdated` is one of: `fill`, `add_margin`, `liquidation`, `settlement` — it
tells the mapper which table write path to take without re-deriving it from context.

## Idempotency

Every ingest write keys on the event's `(tx_version, event_index)` pair. Aptos has instant
finality, so there is no reorg handling — a replay of the same version/index pair is always a
no-op upsert.
