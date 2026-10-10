/// The series registry: which underlyings are approved for trading, and the
/// lifecycle of each contract. Settlement price storage lives here too, since
/// it is intrinsic to a series, but computing and recording it is
/// `settlement`'s job - this module only stores what it's given.
///
/// There is no stored "active/expired" status field. A series is expired the
/// moment `timestamp::now_seconds() >= expiry_ts`; any code that cares (order
/// placement, settlement eligibility) checks the clock directly instead of
/// trusting a flag that could fall out of sync with it.
module zero_day_futures::series {
    use std::option::{Self, Option};
    use std::string::String;
    use aptos_std::table::{Self, Table};
    use aptos_framework::timestamp;
    use zero_day_futures::config;
    use zero_day_futures::events;

    // friend zero_day_futures::settlement; // added once settlement.move exists.

    /// One entry per underlying the admin has approved for trading. Tracks the
    /// Pyth feed to use and the most recently created series, so `roll_series`
    /// only needs the underlying's name to create the next one.
    struct Underlying has copy, drop, store {
        pyth_feed_id: vector<u8>,
        latest_series_id: u64,
    }

    struct SeriesInfo has copy, drop, store {
        underlying: String,
        pyth_feed_id: vector<u8>,
        expiry_ts: u64,
        settlement_price: Option<u64>,
    }

    struct SeriesRegistry has key {
        underlyings: Table<String, Underlying>,
        series: Table<u64, SeriesInfo>,
        next_series_id: u64,
    }

    /// Runs once at publish time. Series ids start at 1 so 0 can mean "no
    /// series yet" in `Underlying.latest_series_id`.
    fun init_module(deployer: &signer) {
        move_to(deployer, SeriesRegistry {
            underlyings: table::new(),
            series: table::new(),
            next_series_id: 1,
        });
    }

    /// Approves `underlying` (e.g. `b"BTC"` as a `String`) for trading against
    /// `pyth_feed_id`, so `roll_series` can create series for it. Admin-only,
    /// local CLI only - the admin key never lives on Vercel.
    public entry fun add_underlying(
        admin: &signer, underlying: String, pyth_feed_id: vector<u8>,
    ) acquires SeriesRegistry {
        config::assert_is_admin(admin);
        let registry = borrow_global_mut<SeriesRegistry>(@zero_day_futures);
        table::upsert(&mut registry.underlyings, underlying, Underlying { pyth_feed_id, latest_series_id: 0 });
    }

    /// Creates a series with an explicit expiry: the standard 24h cycle, or a
    /// short-expiry series for live demos. Admin-only.
    public entry fun create_series(
        admin: &signer, underlying: String, pyth_feed_id: vector<u8>, expiry_ts: u64,
    ) acquires SeriesRegistry {
        config::assert_is_admin(admin);
        create_series_internal(underlying, pyth_feed_id, expiry_ts);
    }

    /// Creates the next standard-duration series for an already-approved
    /// underlying. Permissionless - anyone (in practice the keeper) can call
    /// this once the previous series has expired.
    public entry fun roll_series(underlying: String) acquires SeriesRegistry {
        let pyth_feed_id = {
            let registry = borrow_global<SeriesRegistry>(@zero_day_futures);
            assert!(
                table::contains(&registry.underlyings, underlying),
                config::e_underlying_not_registered(),
            );
            table::borrow(&registry.underlyings, underlying).pyth_feed_id
        };
        let expiry_ts = timestamp::now_seconds() + config::series_duration_seconds();
        create_series_internal(underlying, pyth_feed_id, expiry_ts);
    }

    fun create_series_internal(
        underlying: String, pyth_feed_id: vector<u8>, expiry_ts: u64,
    ): u64 acquires SeriesRegistry {
        let registry = borrow_global_mut<SeriesRegistry>(@zero_day_futures);
        let series_id = registry.next_series_id;
        registry.next_series_id = series_id + 1;

        table::add(&mut registry.series, series_id, SeriesInfo {
            underlying,
            pyth_feed_id,
            expiry_ts,
            settlement_price: option::none(),
        });

        if (table::contains(&registry.underlyings, underlying)) {
            table::borrow_mut(&mut registry.underlyings, underlying).latest_series_id = series_id;
        };

        events::emit_series_created(series_id, underlying, pyth_feed_id, expiry_ts);
        series_id
    }

    #[view]
    public fun exists_series(series_id: u64): bool acquires SeriesRegistry {
        table::contains(&borrow_global<SeriesRegistry>(@zero_day_futures).series, series_id)
    }

    #[view]
    /// `(underlying, pyth_feed_id, expiry_ts, is_settled, settlement_price)`.
    /// `settlement_price` is meaningless when `is_settled` is false - callers
    /// must check that flag, not treat 0 as "unset".
    public fun get_series(series_id: u64): (String, vector<u8>, u64, bool, u64) acquires SeriesRegistry {
        let registry = borrow_global<SeriesRegistry>(@zero_day_futures);
        let info = table::borrow(&registry.series, series_id);
        let is_settled = option::is_some(&info.settlement_price);
        let settlement_price = if (is_settled) { *option::borrow(&info.settlement_price) } else { 0 };
        (info.underlying, info.pyth_feed_id, info.expiry_ts, is_settled, settlement_price)
    }

    #[view]
    public fun is_expired(series_id: u64): bool acquires SeriesRegistry {
        let registry = borrow_global<SeriesRegistry>(@zero_day_futures);
        timestamp::now_seconds() >= table::borrow(&registry.series, series_id).expiry_ts
    }

    #[view]
    public fun get_latest_series_id(underlying: String): u64 acquires SeriesRegistry {
        let registry = borrow_global<SeriesRegistry>(@zero_day_futures);
        assert!(table::contains(&registry.underlyings, underlying), config::e_underlying_not_registered());
        table::borrow(&registry.underlyings, underlying).latest_series_id
    }

    /// Records the settlement price for a series exactly once - the second and
    /// later calls for the same series are no-ops, which is what lets
    /// `settlement::settle_positions` call this unconditionally on every batch
    /// without re-checking who "won" the race to fix the price.
    public(friend) fun set_settlement_price_if_unset(series_id: u64, price: u64) acquires SeriesRegistry {
        let registry = borrow_global_mut<SeriesRegistry>(@zero_day_futures);
        let info = table::borrow_mut(&mut registry.series, series_id);
        if (option::is_none(&info.settlement_price)) {
            option::fill(&mut info.settlement_price, price);
        };
    }

    #[test_only]
    public fun init_module_for_test(deployer: &signer) {
        init_module(deployer);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_add_underlying_then_roll_series_creates_series(deployer: &signer) acquires SeriesRegistry {
        init_module_for_test(deployer);
        config::init_module_for_test(deployer);
        let btc = std::string::utf8(b"BTC");
        add_underlying(deployer, btc, b"pyth-btc-feed");

        let series_id = create_series_internal(btc, b"pyth-btc-feed", 86_400);
        assert!(series_id == 1, 0);
        assert!(exists_series(series_id), 1);
        assert!(get_latest_series_id(btc) == series_id, 2);

        let (underlying, feed, expiry_ts, is_settled, _price) = get_series(series_id);
        assert!(underlying == btc, 3);
        assert!(feed == b"pyth-btc-feed", 4);
        assert!(expiry_ts == 86_400, 5);
        assert!(!is_settled, 6);
    }

    #[test(deployer = @zero_day_futures)]
    #[expected_failure(abort_code = 15, location = Self)] // config::E_UNDERLYING_NOT_REGISTERED
    fun test_roll_series_rejects_unregistered_underlying(deployer: &signer) acquires SeriesRegistry {
        init_module_for_test(deployer);
        roll_series(std::string::utf8(b"DOGE"));
    }

    #[test(deployer = @zero_day_futures, not_admin = @0xB0B)]
    #[expected_failure(abort_code = 1, location = zero_day_futures::config)] // config::E_NOT_ADMIN
    fun test_add_underlying_requires_admin(
        deployer: &signer, not_admin: &signer,
    ) acquires SeriesRegistry {
        init_module_for_test(deployer);
        add_underlying(not_admin, std::string::utf8(b"BTC"), b"pyth-btc-feed");
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    fun test_set_settlement_price_is_idempotent(
        deployer: &signer, aptos_framework: &signer,
    ) acquires SeriesRegistry {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module_for_test(deployer);
        let btc = std::string::utf8(b"BTC");
        let series_id = create_series_internal(btc, b"pyth-btc-feed", 0);

        set_settlement_price_if_unset(series_id, 65_000_000_000);
        set_settlement_price_if_unset(series_id, 70_000_000_000); // should be ignored

        let (_underlying, _feed, _expiry, is_settled, price) = get_series(series_id);
        assert!(is_settled, 0);
        assert!(price == 65_000_000_000, 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    fun test_is_expired_reflects_clock(
        deployer: &signer, aptos_framework: &signer,
    ) acquires SeriesRegistry {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module_for_test(deployer);
        let btc = std::string::utf8(b"BTC");
        let series_id = create_series_internal(btc, b"pyth-btc-feed", 100);

        assert!(!is_expired(series_id), 0);
        timestamp::fast_forward_seconds(100);
        assert!(is_expired(series_id), 1);
    }
}
