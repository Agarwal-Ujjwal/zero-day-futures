# Business Rules

These rules are implemented exactly once, in Move. `lib/math` mirrors the arithmetic for
display/pre-filtering only — **the contract is always the authority**, and the UI/keeper never
trusts its own computation over an on-chain re-check.

## Position model

One **net** position per `(trader, series)`. A non-reduce-only order on the opposite side of an
existing position is rejected outright — there is no flipping (long-to-short or vice versa) in a
single order. A reduce-only order may not exceed the current position size.

## Order margin lock

Initial margin = `10% * price * size`, locked on the trader's balance at order placement and
converted into position margin on fill. Released back to free balance on cancel or on expiry
(cancels remain allowed after expiry).

## Margin and PnL

- Position equity = `margin + (index_price - entry_price) * size`, with the sign flipped for
  shorts.
- Liquidatable when `equity < 5% * notional_at_index`.
- Liquidation penalty = `1% * notional`, paid to the insurance fund.

## Backstop liquidation

A liquidated position is transferred **at index price** to the insurance-fund account, which holds
positions like any other trader but with no margin checks. This means liquidation never depends on
order-book liquidity — there is no need to find a counterparty. Backstop positions settle at
expiry exactly like all others.

## Settlement payout

`payout = max(0, margin + PnL)`. Shortfalls (payout would be negative) are drawn from the
insurance fund. If the fund itself is empty, the shortfall is recorded as bad debt — auto-
deleveraging to redistribute that debt is explicitly P2 and out of scope; this is a documented
residual risk to state in the demo.

## Expiry and settlement timing

Trading halts at the series' `expiry_ts` (cancels remain allowed). The settlement price is a Pyth
price published **at or after** expiry, and the **first** successful `settle_positions` call within
a short window after expiry fixes it for the whole series — later calls reuse the stored price. If
the window is missed, the latest available price at or after expiry is accepted instead. This
keeper-timeliness assumption must be stated explicitly in any demo or writeup.

## Matching

Price-time priority. Each `place_order` transaction has a hard cap on the number of fills it can
produce, to bound gas; any remainder rests on the book (GTC) or is cancelled (IOC).

## Self-trade

A match that would cross a trader's own resting order aborts rather than silently matching.

## Truth hierarchy

Chain state is authoritative over the DB for anything involving money: free balance, margin,
position size. The DB is read for history, aggregates and lists (trades, candles, volume) only.
Any screen that needs an order-entry number (deposit/withdraw limits, margin required to place an
order) reads it from a chain view call, never from Postgres.
