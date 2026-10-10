# API and Entry Point Contract

## Off-chain HTTP endpoints (`src/app/api/*`)

| Method | Endpoint | Purpose | Auth | Request | Response |
|---|---|---|---|---|---|
| GET | `/api/markets` | Active series with index price, last price, 24h volume, open interest, expiry | None | - | list of series stats |
| GET | `/api/markets/[seriesId]/book` | Order-book depth (aggregated levels) | None | `levels` (<=20) | `bids[]`, `asks[]` |
| GET | `/api/markets/[seriesId]/trades` | Recent trades | None | `limit` | `trades[]` |
| GET | `/api/markets/[seriesId]/candles` | OHLCV candles | None | `interval`, `limit` | `candles[]` |
| GET | `/api/oracle/price` | Index prices (Hermes proxy, hides the API key) | None | `feed ids` | `price`, `conf`, `publish_time` |
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
| `liquidate(series, trader, price_update)` | Anyone; keeper in practice | Verify the margin condition on-chain, close at index price |
| `settle_positions(series, traders <=25, price_update)` | Anyone; keeper in practice | Set the settlement price once, then realize PnL for the listed traders |
| `roll_series` | Anyone | Create the next 24h series for a whitelisted underlying |
| `create_series`, `add_underlying`, `set_params` | Admin, local CLI only | Admin key never lives on Vercel |

**Views:** `get_depth`, `get_balance`, `get_position`, `get_series`.

Every entry function and view above must exist with this exact name in
`contracts/sources/*.move`, and every one of them must have a matching payload builder (for entry
functions) or reader (for views) in `src/lib/chain/payloads/` / `src/lib/chain/views/`. If a name
changes on one side, it must change on both in the same commit.
