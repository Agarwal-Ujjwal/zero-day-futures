/// All event structs and their emit functions live here (docs/spec/events.md), so
/// the event contract the indexer depends on is defined in exactly one file. Each
/// producing module gets `emit_*` access via `friend`; nothing outside this
/// package can emit these events.
///
/// This file grows alongside the modules that need it - only `Deposited` and
/// `Withdrawn` exist so far, because `vault` is the only module built that emits
/// anything yet. `SeriesCreated`, `OrderPlaced`, `TradeExecuted`, `PositionUpdated`
/// and the rest are added when `series`, `orders`, `matching`, `clearing`,
/// `liquidation` and `settlement` are implemented.
module zero_day_futures::events {
    use aptos_framework::event;

    friend zero_day_futures::vault;

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

    public(friend) fun emit_deposited(trader: address, amount: u64) {
        event::emit(Deposited { trader, amount });
    }

    public(friend) fun emit_withdrawn(trader: address, amount: u64) {
        event::emit(Withdrawn { trader, amount });
    }
}
