# Units and Constants

These values must be defined exactly once in `contracts/sources/config.move` and mirrored exactly
once in `src/lib/chain/constants.ts`. No other file should hardcode them.

| Quantity | Representation |
|---|---|
| Price | USD, fixed-point with **6 decimals** (e.g. `65_000_000000` = $65,000.00) |
| Size | Lots of **0.0001** of the underlying (e.g. 1 BTC = `10000` lots) |
| Collateral (mock USDC) | **6 decimals**, matching real USDC |
| Notional | `price * size`, computed with a wide (u128) intermediate before narrowing |

## Risk parameters (defaults — final values live in `config.move`)

| Parameter | Value | Used by |
|---|---|---|
| Max leverage | 10x | order placement (initial margin check) |
| Initial margin rate | 10% of notional | `place_order` margin lock |
| Maintenance margin rate | 5% of notional | `liquidate` condition, UI margin-health |
| Margin-call warning threshold | 1.5x maintenance margin | UI banner only, not enforced on-chain |
| Liquidation penalty | 1% of notional, paid to insurance fund | `liquidate` |
| Settlement batch size | <=25 traders per `settle_positions` call | keeper batching |
| Series expiry | 24h (n-day series are a later extension of the same `series` module) | `series.move` |

## Why this file exists

Price/size/decimals mismatches between Move and TypeScript are a silent-corruption class of bug —
the contract and the UI would both "work" but disagree on what a trade means. Treat this file as
the single source of truth to diff against when adding a new underlying or changing a rate.
