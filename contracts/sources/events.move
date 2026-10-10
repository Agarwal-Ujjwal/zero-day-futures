/// All event structs and their emit functions live here (docs/spec/events.md), so
/// the event contract the indexer depends on is defined in exactly one file. Each
/// producing module gets `emit_*` access via `friend`; nothing outside this
/// package can emit these events.
///
module zero_day_futures::events {
    use std::string::String;
    use aptos_framework::event;

    friend zero_day_futures::vault;
    friend zero_day_futures::series;
    friend zero_day_futures::clearing;
    friend zero_day_futures::orders;
    friend zero_day_futures::matching;
    friend zero_day_futures::liquidation;
    friend zero_day_futures::settlement;

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

    #[event]
    /// A new order was submitted. `remaining` and `size` can differ: a
    /// marketable order may already be partly or fully filled by the time
    /// this fires, since it carries post-match state like every other event
    /// here (docs/spec/events.md). There is no `status` field - the mapper
    /// derives `open`/`partial`/`filled` by comparing `remaining` to `size`.
    struct OrderPlaced has drop, store {
        order_id: u64,
        series_id: u64,
        trader: address,
        side: u8,
        price: u64,
        size: u64,
        remaining: u64,
        tif: u8,
        reduce_only: bool,
    }

    #[event]
    /// An existing order's remaining size or status changed - a fill against
    /// it as a resting maker, or a cancellation. `status` is explicit here
    /// (unlike `OrderPlaced`) because `cancelled` can't be inferred from
    /// `remaining` alone.
    struct OrderUpdated has drop, store {
        order_id: u64,
        remaining: u64,
        status: u8,
    }

    #[event]
    /// One matched fill between a resting maker and an incoming taker.
    struct TradeExecuted has drop, store {
        series_id: u64,
        price: u64,
        size: u64,
        maker: address,
        taker: address,
        taker_side: u8,
    }

    #[event]
    /// A position was closed by `liquidation::liquidate` rather than by its
    /// own trader. `price` is the index price it closed at; `penalty` is the
    /// share of the gross payout redirected to the insurance fund instead of
    /// back to the trader.
    struct Liquidated has drop, store {
        trader: address,
        series_id: u64,
        price: u64,
        penalty: u64,
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

    public(friend) fun emit_order_placed(
        order_id: u64,
        series_id: u64,
        trader: address,
        side: u8,
        price: u64,
        size: u64,
        remaining: u64,
        tif: u8,
        reduce_only: bool,
    ) {
        event::emit(OrderPlaced { order_id, series_id, trader, side, price, size, remaining, tif, reduce_only });
    }

    public(friend) fun emit_order_updated(order_id: u64, remaining: u64, status: u8) {
        event::emit(OrderUpdated { order_id, remaining, status });
    }

    public(friend) fun emit_trade_executed(
        series_id: u64, price: u64, size: u64, maker: address, taker: address, taker_side: u8,
    ) {
        event::emit(TradeExecuted { series_id, price, size, maker, taker, taker_side });
    }

    public(friend) fun emit_liquidated(trader: address, series_id: u64, price: u64, penalty: u64) {
        event::emit(Liquidated { trader, series_id, price, penalty });
    }
}
