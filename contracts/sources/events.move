/// All event structs and their emit functions live here (docs/spec/events.md), so
/// the event contract the indexer depends on is defined in exactly one file. Each
/// producing module gets `emit_*` access via `friend`; nothing outside this
/// package can emit these events.
///
/// This file grows alongside the modules that need it. `OrderPlaced` and
/// `TradeExecuted` are added when `orders` and `matching` are implemented.
module zero_day_futures::events {
    use std::string::String;
    use aptos_framework::event;

    friend zero_day_futures::vault;
    friend zero_day_futures::series;
    friend zero_day_futures::clearing;

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

    #[event]
    /// A position changed shape - opened, increased, reduced, closed, or had
    /// margin added. `reason` is one of `position::reason_*()`. `side`,
    /// `size`, `entry_price` and `margin` are the resulting state, not a
    /// delta - mappers copy this straight into the `positions` table row.
    struct PositionUpdated has drop, store {
        series_id: u64,
        trader: address,
        side: u8,
        size: u64,
        entry_price: u64,
        margin: u64,
        realized_pnl_is_negative: bool,
        realized_pnl_magnitude: u64,
        reason: u8,
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

    public(friend) fun emit_position_updated(
        series_id: u64,
        trader: address,
        side: u8,
        size: u64,
        entry_price: u64,
        margin: u64,
        realized_pnl_is_negative: bool,
        realized_pnl_magnitude: u64,
        reason: u8,
    ) {
        event::emit(PositionUpdated {
            series_id, trader, side, size, entry_price, margin,
            realized_pnl_is_negative, realized_pnl_magnitude, reason,
        });
    }
}
