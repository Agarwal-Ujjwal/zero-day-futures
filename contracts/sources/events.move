/// All event structs and their emit functions live here (docs/spec/events.md), so
/// the event contract the indexer depends on is defined in exactly one file. Each
/// producing module gets `emit_*` access via `friend`; nothing outside this
/// package can emit these events.
///
/// This file grows alongside the modules that need it. `OrderPlaced`,
/// `TradeExecuted`, `PositionUpdated` and the rest are added when `orders`,
/// `matching`, `clearing`, `liquidation` and `settlement` are implemented.
module zero_day_futures::events {
    use std::string::String;
    use aptos_framework::event;

    friend zero_day_futures::vault;
    friend zero_day_futures::series;

    #[event]
    /// A trader moved collateral from their own wallet into vault custody.
    struct Deposited has drop, store {
        trader: address,
        amount: u64,
    }

    #[event]
    /// A trader moved collateral from their vault free balance back to their wallet.
    struct Withdrawn has drop, store {
        trader: address,
        amount: u64,
    }

    #[event]
    /// A new series was opened, via `create_series` or `roll_series`.
    struct SeriesCreated has drop, store {
        series_id: u64,
        underlying: String,
        pyth_feed_id: vector<u8>,
        expiry_ts: u64,
    }

    public(friend) fun emit_deposited(trader: address, amount: u64) {
        event::emit(Deposited { trader, amount });
    }

    public(friend) fun emit_withdrawn(trader: address, amount: u64) {
        event::emit(Withdrawn { trader, amount });
    }

    public(friend) fun emit_series_created(
        series_id: u64, underlying: String, pyth_feed_id: vector<u8>, expiry_ts: u64,
    ) {
        event::emit(SeriesCreated { series_id, underlying, pyth_feed_id, expiry_ts });
    }
}
