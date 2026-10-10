/// The `Position` struct and its storage, with accessors only - no netting,
/// PnL, or margin math lives here (that's `clearing` and `margin`). Every
/// position, for every trader and series, lives in one table under the package
/// address rather than under each trader's own account. That is what lets
/// `clearing` update a *maker's* position inside a *taker's* transaction, and
/// lets `liquidation`/`settlement` update any trader's position from a
/// permissionless keeper call - none of those callers can produce that
/// trader's signature, and storing per-trader would require one.
module zero_day_futures::position {
    use aptos_std::table::{Self, Table};
    use zero_day_futures::margin;

    friend zero_day_futures::clearing;
    friend zero_day_futures::settlement;

    const STATUS_OPEN: u8 = 0;
    const STATUS_CLOSED: u8 = 1;
    const STATUS_LIQUIDATED: u8 = 2;
    const STATUS_SETTLED: u8 = 3;

    public fun status_open(): u8 { STATUS_OPEN }
    public fun status_closed(): u8 { STATUS_CLOSED }
    public fun status_liquidated(): u8 { STATUS_LIQUIDATED }
    public fun status_settled(): u8 { STATUS_SETTLED }

    /// Why a `PositionUpdated` event fired - shared across every module that
    /// touches a position, so the DB mapper (docs/spec/events.md) can route on
    /// one byte instead of re-deriving the cause from context.
    const REASON_FILL: u8 = 0;
    const REASON_ADD_MARGIN: u8 = 1;
    const REASON_LIQUIDATION: u8 = 2;
    const REASON_SETTLEMENT: u8 = 3;

    public fun reason_fill(): u8 { REASON_FILL }
    public fun reason_add_margin(): u8 { REASON_ADD_MARGIN }
    public fun reason_liquidation(): u8 { REASON_LIQUIDATION }
    public fun reason_settlement(): u8 { REASON_SETTLEMENT }

    /// One net position per (series, trader) - docs/spec/business-rules.md
    /// rules out flipping, so this never needs to represent more than one side.
    struct Position has copy, drop, store {
        side: u8,
        size: u64,
        entry_price: u64,
        margin: u64,
        realized_pnl_is_negative: bool,
        realized_pnl_magnitude: u64,
        status: u8,
    }

    struct PositionKey has copy, drop, store {
        series_id: u64,
        trader: address,
    }

    struct PositionStore has key {
        positions: Table<PositionKey, Position>,
    }

    /// Runs once at publish time.
    fun init_module(deployer: &signer) {
        move_to(deployer, PositionStore { positions: table::new() });
    }

    /// A position with nothing open - what `get_position` returns for any
    /// (series, trader) pair that has never traded.
    public fun empty_position(): Position {
        Position {
            side: margin::side_long(),
            size: 0,
            entry_price: 0,
            margin: 0,
            realized_pnl_is_negative: false,
            realized_pnl_magnitude: 0,
            status: STATUS_CLOSED,
        }
    }

    public fun new_position(
        side: u8,
        size: u64,
        entry_price: u64,
        margin_amount: u64,
        realized_pnl_is_negative: bool,
        realized_pnl_magnitude: u64,
        status: u8,
    ): Position {
        Position {
            side, size, entry_price, margin: margin_amount,
            realized_pnl_is_negative, realized_pnl_magnitude, status,
        }
    }

    public fun side_of(position: &Position): u8 { position.side }
    public fun size_of(position: &Position): u64 { position.size }
    public fun entry_price_of(position: &Position): u64 { position.entry_price }
    public fun margin_of(position: &Position): u64 { position.margin }
    public fun status_of(position: &Position): u8 { position.status }
    public fun is_open(position: &Position): bool { position.status == STATUS_OPEN }

    public fun realized_pnl_of(position: &Position): (bool, u64) {
        (position.realized_pnl_is_negative, position.realized_pnl_magnitude)
    }

    #[view]
    public fun has_position(trader: address, series_id: u64): bool acquires PositionStore {
        let store = borrow_global<PositionStore>(@zero_day_futures);
        table::contains(&store.positions, PositionKey { series_id, trader })
    }

    #[view]
    /// Current position for (series, trader). Reads as `empty_position()`
    /// rather than aborting when the pair has never traded.
    public fun get_position(trader: address, series_id: u64): Position acquires PositionStore {
        let store = borrow_global<PositionStore>(@zero_day_futures);
        let key = PositionKey { series_id, trader };
        if (table::contains(&store.positions, key)) {
            *table::borrow(&store.positions, key)
        } else {
            empty_position()
        }
    }

    /// Replaces the full stored state for (series, trader). Callers always
    /// compute the complete new `Position` themselves - this module does not
    /// merge or validate it, by design (see the module doc comment).
    public(friend) fun upsert_position(
        trader: address, series_id: u64, position: Position,
    ) acquires PositionStore {
        let store = borrow_global_mut<PositionStore>(@zero_day_futures);
        table::upsert(&mut store.positions, PositionKey { series_id, trader }, position);
    }

    #[test_only]
    public fun init_module_for_test(deployer: &signer) {
        init_module(deployer);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_get_position_defaults_to_empty(deployer: &signer) acquires PositionStore {
        init_module_for_test(deployer);
        let position = get_position(@0xCAFE, 1);
        assert!(!is_open(&position), 0);
        assert!(size_of(&position) == 0, 1);
        assert!(!has_position(@0xCAFE, 1), 2);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_upsert_then_get_position_round_trips(deployer: &signer) acquires PositionStore {
        init_module_for_test(deployer);
        let trader = @0xCAFE;
        let series_id = 1;
        let position = new_position(
            margin::side_long(), 10_000, 65_000_000_000, 6_500_000_000, false, 0, status_open(),
        );
        upsert_position(trader, series_id, position);

        assert!(has_position(trader, series_id), 0);
        let fetched = get_position(trader, series_id);
        assert!(side_of(&fetched) == margin::side_long(), 1);
        assert!(size_of(&fetched) == 10_000, 2);
        assert!(entry_price_of(&fetched) == 65_000_000_000, 3);
        assert!(margin_of(&fetched) == 6_500_000_000, 4);
        assert!(is_open(&fetched), 5);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_upsert_overwrites_existing_position(deployer: &signer) acquires PositionStore {
        init_module_for_test(deployer);
        let trader = @0xCAFE;
        let series_id = 1;
        upsert_position(
            trader, series_id,
            new_position(margin::side_long(), 10_000, 65_000_000_000, 6_500_000_000, false, 0, status_open()),
        );
        upsert_position(
            trader, series_id,
            new_position(margin::side_long(), 20_000, 66_000_000_000, 13_200_000_000, false, 0, status_open()),
        );

        let fetched = get_position(trader, series_id);
        assert!(size_of(&fetched) == 20_000, 0);
        assert!(entry_price_of(&fetched) == 66_000_000_000, 1);
    }
}
