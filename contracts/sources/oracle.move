/// Index price storage and staleness checks for `liquidation` and
/// `settlement`.
///
/// This was designed around Pyth's pull-oracle model (the caller supplies a
/// fresh cross-chain price update in the same transaction, and this module
/// would verify and apply it). That is no longer possible: Pyth Core
/// discontinued Aptos support entirely on 2026-08-26, not just added
/// friction - there is no contract left to call. Per docs/architecture.md's
/// pre-approved fallback, this module instead takes a push model: the
/// keeper account posts a price it fetched off-chain, and `liquidate`/
/// `settle_positions` just read whatever was posted most recently, with a
/// staleness check standing in for Pyth's own freshness guarantee.
///
/// The function name `get_price_no_older_than` and its staleness-check
/// shape are kept identical to Pyth's own API on purpose, so a real oracle
/// (Chainlink and Supra both support Aptos today) could replace this
/// module's internals later without changing any caller.
///
/// Trust model, stated plainly: a price is only as trustworthy as the
/// keeper account that posted it. A compromised keeper key cannot move
/// funds (every other module validates its own conditions independently),
/// but it could post a false price and trigger a wrongful liquidation or
/// settlement - a strictly weaker guarantee than a verified Pyth
/// attestation would have given. This is a documented residual risk of the
/// fallback, not an oversight.
module zero_day_futures::oracle {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use aptos_framework::timestamp;
    use zero_day_futures::config;

    struct PriceFeed has copy, drop, store {
        price: u64,
        posted_at: u64,
    }

    struct OracleStore has key {
        keeper: address,
        prices: Table<vector<u8>, PriceFeed>,
    }

    /// Runs once at publish time. The admin is the keeper until `set_keeper`
    /// rotates it to the account that actually runs the keeper tick.
    fun init_module(deployer: &signer) {
        move_to(deployer, OracleStore {
            keeper: signer::address_of(deployer),
            prices: table::new(),
        });
    }

    /// Rotates which account may call `post_price`. Admin-only - this is how
    /// the keeper's price-posting authority stays separate from the admin
    /// capability itself, so the keeper key (which does run on Vercel) is
    /// never the admin key (which never does).
    public entry fun set_keeper(admin: &signer, new_keeper: address) acquires OracleStore {
        config::assert_is_admin(admin);
        borrow_global_mut<OracleStore>(@zero_day_futures).keeper = new_keeper;
    }

    /// Posts the current price for `feed_id`, stamped with this transaction's
    /// on-chain time. Keeper-only.
    public entry fun post_price(keeper: &signer, feed_id: vector<u8>, price: u64) acquires OracleStore {
        let store = borrow_global_mut<OracleStore>(@zero_day_futures);
        assert!(signer::address_of(keeper) == store.keeper, config::e_not_keeper());
        table::upsert(&mut store.prices, feed_id, PriceFeed { price, posted_at: timestamp::now_seconds() });
    }

    /// Returns `(price, posted_at)` for `feed_id`. Aborts with
    /// `E_ORACLE_PRICE_STALE` if no price has ever been posted for this feed,
    /// or if the one on file is older than `max_age_secs`.
    public fun get_price_no_older_than(feed_id: vector<u8>, max_age_secs: u64): (u64, u64) acquires OracleStore {
        let store = borrow_global<OracleStore>(@zero_day_futures);
        assert!(table::contains(&store.prices, feed_id), config::e_oracle_price_stale());
        let feed = table::borrow(&store.prices, feed_id);
        assert!(timestamp::now_seconds() - feed.posted_at <= max_age_secs, config::e_oracle_price_stale());
        (feed.price, feed.posted_at)
    }

    #[view]
    /// The latest posted price for `feed_id` regardless of staleness, for
    /// display purposes (e.g. the `/api/oracle/price` route). Safety-critical
    /// reads must go through `get_price_no_older_than` instead.
    public fun get_latest_price(feed_id: vector<u8>): (u64, u64) acquires OracleStore {
        let store = borrow_global<OracleStore>(@zero_day_futures);
        if (!table::contains(&store.prices, feed_id)) {
            return (0, 0)
        };
        let feed = table::borrow(&store.prices, feed_id);
        (feed.price, feed.posted_at)
    }

    #[test_only]
    public fun init_module_for_test(deployer: &signer) {
        init_module(deployer);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    fun test_post_price_then_read_it(deployer: &signer, aptos_framework: &signer) acquires OracleStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module_for_test(deployer);
        post_price(deployer, b"BTC", 65_000_000_000);

        let (price, posted_at) = get_price_no_older_than(b"BTC", 90);
        assert!(price == 65_000_000_000, 0);
        assert!(posted_at == timestamp::now_seconds(), 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 8, location = Self)] // config::E_ORACLE_PRICE_STALE
    fun test_get_price_aborts_when_never_posted(deployer: &signer, aptos_framework: &signer) acquires OracleStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module_for_test(deployer);
        get_price_no_older_than(b"BTC", 90);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 8, location = Self)] // config::E_ORACLE_PRICE_STALE
    fun test_get_price_aborts_when_stale(deployer: &signer, aptos_framework: &signer) acquires OracleStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module_for_test(deployer);
        post_price(deployer, b"BTC", 65_000_000_000);
        timestamp::fast_forward_seconds(91);
        get_price_no_older_than(b"BTC", 90);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, impostor = @0xB0B)]
    #[expected_failure(abort_code = 19, location = Self)] // config::E_NOT_KEEPER
    fun test_non_keeper_cannot_post_price(
        deployer: &signer, aptos_framework: &signer, impostor: &signer,
    ) acquires OracleStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module_for_test(deployer);
        post_price(impostor, b"BTC", 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, new_keeper = @0xCAFE)]
    fun test_set_keeper_rotates_posting_authority(
        deployer: &signer, aptos_framework: &signer, new_keeper: &signer,
    ) acquires OracleStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        config::init_module_for_test(deployer);
        init_module_for_test(deployer);
        set_keeper(deployer, signer::address_of(new_keeper));

        post_price(new_keeper, b"BTC", 65_000_000_000);
        let (price, _posted_at) = get_price_no_older_than(b"BTC", 90);
        assert!(price == 65_000_000_000, 0);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 19, location = Self)] // config::E_NOT_KEEPER
    fun test_old_keeper_rejected_after_rotation(deployer: &signer, aptos_framework: &signer) acquires OracleStore {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        config::init_module_for_test(deployer);
        init_module_for_test(deployer);
        set_keeper(deployer, @0xCAFE);
        post_price(deployer, b"BTC", 1);
    }
}
