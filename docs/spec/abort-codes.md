# Abort Codes

Move abort codes are defined once as an enumerated list in `contracts/sources/config.move` and
mirrored once in the TS error map at `src/lib/chain/errors.ts`, which turns a raw abort code
surfaced by the Aptos SDK into a human-readable message for the UI.

This list is the planned starting set (drawn from the business rules and security sections of
`docs/architecture.md`). It is **not final** — `config.move` is the source of truth once written;
update this table in the same commit as any change to the Move enum.

| Code (symbolic name) | Raised by | Meaning |
|---|---|---|
| `E_INSUFFICIENT_FREE_BALANCE` | `vault::withdraw`, `orders::place_order` | Not enough free balance to cover the withdrawal or initial margin |
| `E_REDUCE_ONLY_VIOLATION` | `orders::place_order` | A reduce-only order's size exceeds the current position |
| `E_POSITION_FLIP_NOT_ALLOWED` | `clearing::apply_fill` | A non-reduce-only order would flip an existing position to the other side |
| `E_SERIES_EXPIRED` | `orders::place_order` | Series has passed its `expiry_ts`; new orders are rejected (cancels still allowed) |
| `E_SERIES_NOT_EXPIRED` | `settlement::settle_positions` | Settlement attempted before `expiry_ts` |
| `E_SELF_TRADE` | `matching` | A match would cross the same trader's own order |
| `E_ORACLE_PRICE_STALE` | `oracle::get_price` | Pyth price is older than the allowed staleness window |
| `E_SETTLEMENT_PRICE_TOO_EARLY` | `settlement::settle_positions` | Supplied Pyth price is timestamped before `expiry_ts` |
| `E_POSITION_HEALTHY` | `liquidation::liquidate` | Re-verified on-chain equity is above the maintenance margin; liquidation aborts harmlessly |
| `E_BATCH_TOO_LARGE` | `settlement::settle_positions` | Trader list exceeds the per-call cap (25) |
| `E_OPEN_ORDER_CAP_EXCEEDED` | `orders::place_order` | Trader already has the maximum open orders for this series |
| `E_FILLS_CAP_EXCEEDED` | `matching` | A single `place_order` call hit its max-fills-per-tx bound (remainder rests or cancels, this is not a user-facing failure) |
| `E_NOT_ADMIN` | `series::create_series`, `series::add_underlying`, `config::set_params` | Caller does not hold the admin capability |
| `E_FAUCET_COOLDOWN` | `collateral::faucet_mint` | Caller already claimed the faucet within the last 24h |
| `E_UNDERLYING_NOT_REGISTERED` | `series::roll_series` | Admin has not called `add_underlying` for this underlying yet |
| `E_NO_OPEN_POSITION` | `clearing::add_margin` | Caller has no open position on this series to add margin to |
| `E_ORDER_NOT_FOUND` | `orders::cancel_order` | No resting order with this id (already filled or already cancelled) |
| `E_NOT_ORDER_OWNER` | `orders::cancel_order` | Caller is not the order's trader, and the series has not expired (anyone may cancel on an expired series) |
| `E_NOT_KEEPER` | `oracle::post_price` | Caller is not the account currently authorized to post prices (see `oracle::set_keeper`) |

## Convention

Each code is a plain `u64` constant in `config.move`, grouped by module with a comment naming the
module it belongs to. `errors.ts` keys on the numeric code (not the symbolic name, which doesn't
survive compilation) and must be updated whenever `config.move`'s constants change.
