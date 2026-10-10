# API and Entry Point Contract

## Off-chain HTTP endpoints (`src/app/api/*`)

| Method | Endpoint | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| GET | `/api/markets` | Active series with index price, last price, 24h volume, open interest, expiry | None | - | list of series stats |
| GET | `/api/markets/[seriesId]/book` | Order-book depth (aggregated levels) | None | `levels` (<=20) | `bids[]`, `asks[]` |
| GET | `/api/markets/[seriesId]/trades` | Recent trades | None | `limit` | `trades[]` |
| GET | `/api/markets/[seriesId]/candles` | OHLCV candles | None | `interval`, `limit` | `candles[]` |
| GET | `/api/oracle/price` | Index prices (reads `oracle::get_latest_price`; see the Pyth-discontinued note in `docs/architecture.md`) | None | `feed ids` | `price`, `posted_at` |
| GET | `/api/accounts/[address]` | Positions, open orders, history | None (public chain data) | `address` | `positions[]`, `orders[]`, `events[]` |
| GET | `/api/keeper/tick` | Sync + keeper duties | Bearer `CRON_SECRET` | - | summary of work done |
| GET | `/api/health` | Sync lag, last tick | None | - | status |

The keeper tick is `GET` because Vercel Cron only issues `GET` requests. Read endpoints are public
and cached (see `src/lib/api/cache.ts` and the Cache Components note in `docs/architecture.md`).

## On-chain entry points (the "Transaction API")

| Function | Caller | Purpose |
|---|---|---|
| `faucet_mint` | User, browser-signed | Mint test collateral (capped per address per day) |
| `deposit` / `withdraw` | User | Move collateral into/out of the vault (`withdraw` = free balance only) |
| `place_order(series, side, price, size, tif, reduce_only)` | User | Lock initial margin (unless reduce-only), match, rest remainder (GTC) or cancel it (IOC) |
| `cancel_order` | User (anyone, for expired series) | Release locked margin |
| `add_margin` | User | Top up a position (margin-call response) |
| `post_price(feed_id, price)` | Keeper only | Posts the index price the keeper fetched off-chain (see the Pyth-discontinued note below) |
| `liquidate(series, trader)` | Anyone; keeper in practice | Verify the margin condition against the last posted price, close at index price |
| `settle_positions(series, traders <=25)` | Anyone; keeper in practice | Set the settlement price once (from the last posted price), then realize PnL for the listed traders |
| `roll_series` | Anyone | Create the next 24h series for a whitelisted underlying |
| `create_series`, `add_underlying`, `set_params` | Admin, local CLI only | Admin key never lives on Vercel |
| `set_keeper(new_keeper)` | Admin, local CLI only | Rotates which account may call `post_price` - kept separate from the admin capability so the keeper key, which does run on Vercel, is never the admin key |

**Views:** `get_depth`, `get_balance`, `get_position`, `get_series`, `get_latest_price`.

**Pyth is discontinued on Aptos** (as of 2026-08-26), so `liquidate`/`settle_positions` no longer
take a Pyth price-update blob as an argument the way the original architecture plan assumed -
there is nothing left to verify on-chain. Instead they read whatever price the keeper most
recently pushed via `post_price`, through `oracle::get_price_no_older_than`. See
`docs/architecture.md`'s platform notes for the full tradeoff this implies.

Every entry function and view above must exist with this exact name in
`contracts/sources/*.move`, and every one of them must have a matching payload builder (for entry
functions) or reader (for views) in `src/lib/chain/payloads/` / `src/lib/chain/views/`. If a name
changes on one side, it must change on both in the same commit.
