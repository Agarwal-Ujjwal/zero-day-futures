# zero-day-futures
A decentralized, non-custodial futures trading platform built on Aptos.

## Deployed contracts (Aptos testnet)

- Module address: [`0x97a6c5b80194a3dbd6d20b6435da9c845a4f192be2e0aeeb65da18407c48da52`](https://explorer.aptoslabs.com/account/0x97a6c5b80194a3dbd6d20b6435da9c845a4f192be2e0aeeb65da18407c48da52?network=testnet)
- Seeded underlyings: `BTC`, `ETH`, `APT` (feed ids are plain `"<SYMBOL>/USD"` strings, since Pyth is discontinued on Aptos - see `docs/architecture.md`)
- Series `1` (BTC, 24h) is live with a seed index price posted

See `docs/architecture.md` and `docs/spec/` for the full design.
