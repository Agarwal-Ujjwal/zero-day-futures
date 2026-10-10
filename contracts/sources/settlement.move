/// `settle_positions`: fixes the settlement price for an expired series once,
/// then realizes PnL for whichever traders are listed. Permissionless, and
/// the contract never iterates over all positions itself - the keeper
/// supplies address lists from its own DB, in batches of
/// `config::settlement_batch_max()`, repeating until none remain open. Any
/// trader can also settle themselves with just their own address.
module zero_day_futures::settlement {
    use std::vector;
    use zero_day_futures::config;
    use zero_day_futures::events;
    use zero_day_futures::margin;
    use zero_day_futures::oracle;
    use zero_day_futures::position::{Self, Position};
    use zero_day_futures::series;
    use zero_day_futures::vault;

    /// Settles up to `config::settlement_batch_max()` traders' positions on
    /// `series_id` at its settlement price.
    ///
    /// The first call for a series fixes that price: it must come from a
    /// keeper-posted price (`oracle::get_price_no_older_than`) timestamped at
    /// or after the series' expiry, per docs/spec/business-rules.md. Every
    /// later call reuses the price `series::set_settlement_price_if_unset`
    /// already recorded, regardless of what the oracle says by then.
    public entry fun settle_positions(series_id: u64, traders: vector<address>) {
        assert!(vector::length(&traders) <= config::settlement_batch_max(), config::e_batch_too_large());
        assert!(series::is_expired(series_id), config::e_series_not_expired());

        let (_underlying, pyth_feed_id, expiry_ts, is_settled, existing_price) = series::get_series(series_id);
        let settlement_price = if (is_settled) {
            existing_price
        } else {
            let (price, posted_at) =
                oracle::get_price_no_older_than(pyth_feed_id, config::oracle_max_price_age_seconds());
            assert!(posted_at >= expiry_ts, config::e_settlement_price_too_early());
            series::set_settlement_price_if_unset(series_id, price);
            price
        };

        let i = 0;
        let len = vector::length(&traders);
        while (i < len) {
            settle_one(series_id, *vector::borrow(&traders, i), settlement_price);
            i = i + 1;
        };
    }

    /// Settles one trader, or does nothing if they have no open position -
    /// already settled, closed, or liquidated. Tolerating that here (instead
    /// of aborting) is what lets the keeper's batches safely overlap on retry
    /// without needing to track exactly who it already processed.
    fun settle_one(series_id: u64, trader: address, settlement_price: u64) {
        let current = position::get_position(trader, series_id);
        if (!position::is_open(&current)) {
            return
        };

        let side = position::side_of(&current);
        let entry_price = position::entry_price_of(&current);
        let size = position::size_of(&current);

        let payout = margin::settlement_payout(position::margin_of(&current), entry_price, settlement_price, size, side);
        vault::unlock_margin(trader, payout);

        let (fill_is_loss, fill_pnl_magnitude) = margin::pnl(entry_price, settlement_price, size, side);
        let (old_pnl_is_negative, old_pnl_magnitude) = position::realized_pnl_of(&current);
        let (new_pnl_is_negative, new_pnl_magnitude) =
            margin::combine_signed(old_pnl_is_negative, old_pnl_magnitude, fill_is_loss, fill_pnl_magnitude);

        let settled = position::new_position(
            side, 0, entry_price, 0, new_pnl_is_negative, new_pnl_magnitude, position::status_settled(),
        );
        position::upsert_position(trader, series_id, settled);
        emit_position_updated(series_id, trader, &settled);
    }

    fun emit_position_updated(series_id: u64, trader: address, position_ref: &Position) {
        let (pnl_is_negative, pnl_magnitude) = position::realized_pnl_of(position_ref);
        events::emit_position_updated(
            series_id,
            trader,
            position::side_of(position_ref),
            position::size_of(position_ref),
            position::entry_price_of(position_ref),
            position::margin_of(position_ref),
            pnl_is_negative,
            pnl_magnitude,
            position::reason_settlement(),
        );
    }

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use zero_day_futures::clearing;
    #[test_only]
    use zero_day_futures::collateral;
    #[test_only]
    use zero_day_futures::order_book;

    #[test_only]
    const TEST_PRICE_UNIT: u64 = 1_000_000;
    #[test_only]
    const TEST_LOT_UNIT: u64 = 10_000;

    #[test_only]
    const SERIES_DURATION: u64 = 86_400;

    #[test_only]
    fun setup_for_test(deployer: &signer, aptos_framework: &signer): u64 {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        config::init_module_for_test(deployer);
        collateral::init_module_for_test(deployer);
        vault::init_module_for_test(deployer);
        position::init_module_for_test(deployer);
        order_book::init_module_for_test(deployer);
        series::init_module_for_test(deployer);
        oracle::init_module_for_test(deployer);

        let btc = std::string::utf8(b"BTC");
        series::add_underlying(deployer, btc, b"pyth-btc-feed");
        series::create_series(deployer, btc, b"pyth-btc-feed", SERIES_DURATION);
        series::get_latest_series_id(btc)
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_settle_positions_fixes_price_and_credits_a_winner(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        let series_id = setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        let locked_margin = margin::initial_margin(entry, TEST_LOT_UNIT);
        clearing::apply_fill(trader_addr, series_id, margin::side_long(), entry, TEST_LOT_UNIT, locked_margin);

        timestamp::fast_forward_seconds(SERIES_DURATION);
        let settle_price = 70_000 * TEST_PRICE_UNIT;
        oracle::post_price(deployer, b"pyth-btc-feed", settle_price);

        settle_positions(series_id, vector[trader_addr]);

        let (_u, _f, _e, is_settled, recorded_price) = series::get_series(series_id);
        assert!(is_settled, 0);
        assert!(recorded_price == settle_price, 1);

        let expected_payout = margin::settlement_payout(locked_margin, entry, settle_price, TEST_LOT_UNIT, margin::side_long());
        assert!(vault::get_balance(trader_addr) == expected_payout, 2);
        let settled = position::get_position(trader_addr, series_id);
        assert!(position::status_of(&settled) == position::status_settled(), 3);
        assert!(position::size_of(&settled) == 0, 4);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_second_call_reuses_fixed_price(deployer: &signer, aptos_framework: &signer, trader: &signer) {
        let series_id = setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        clearing::apply_fill(
            trader_addr, series_id, margin::side_long(), entry, TEST_LOT_UNIT,
            margin::initial_margin(entry, TEST_LOT_UNIT),
        );
        timestamp::fast_forward_seconds(SERIES_DURATION);
        oracle::post_price(deployer, b"pyth-btc-feed", 70_000 * TEST_PRICE_UNIT);
        settle_positions(series_id, vector[trader_addr]);

        // A different price is posted later; the already-fixed one must win.
        oracle::post_price(deployer, b"pyth-btc-feed", 80_000 * TEST_PRICE_UNIT);
        settle_positions(series_id, vector[]);

        let (_u, _f, _e, _is_settled, recorded_price) = series::get_series(series_id);
        assert!(recorded_price == 70_000 * TEST_PRICE_UNIT, 0);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_settling_twice_is_a_no_op_the_second_time(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        let series_id = setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        clearing::apply_fill(
            trader_addr, series_id, margin::side_long(), entry, TEST_LOT_UNIT,
            margin::initial_margin(entry, TEST_LOT_UNIT),
        );
        timestamp::fast_forward_seconds(SERIES_DURATION);
        oracle::post_price(deployer, b"pyth-btc-feed", 70_000 * TEST_PRICE_UNIT);

        settle_positions(series_id, vector[trader_addr]);
        let balance_after_first = vault::get_balance(trader_addr);
        settle_positions(series_id, vector[trader_addr]); // already closed - skipped, not re-paid

        assert!(vault::get_balance(trader_addr) == balance_after_first, 0);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    #[expected_failure(abort_code = 6, location = Self)] // config::E_SERIES_NOT_EXPIRED
    fun test_settle_positions_rejects_before_expiry(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        let series_id = setup_for_test(deployer, aptos_framework);
        settle_positions(series_id, vector[std::signer::address_of(trader)]);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 9, location = Self)] // config::E_SETTLEMENT_PRICE_TOO_EARLY
    fun test_settle_positions_rejects_price_posted_before_expiry(deployer: &signer, aptos_framework: &signer) {
        let series_id = setup_for_test(deployer, aptos_framework);
        // Posted shortly before expiry - still fresh enough to pass the
        // staleness check, but timestamped earlier than the series' expiry.
        timestamp::fast_forward_seconds(SERIES_DURATION - 50);
        oracle::post_price(deployer, b"pyth-btc-feed", 65_000 * TEST_PRICE_UNIT);
        timestamp::fast_forward_seconds(50);
        settle_positions(series_id, vector[]);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 11, location = Self)] // config::E_BATCH_TOO_LARGE
    fun test_settle_positions_rejects_oversized_batch(deployer: &signer, aptos_framework: &signer) {
        let series_id = setup_for_test(deployer, aptos_framework);
        timestamp::fast_forward_seconds(SERIES_DURATION);
        oracle::post_price(deployer, b"pyth-btc-feed", 65_000 * TEST_PRICE_UNIT);

        let traders = vector::empty<address>();
        let i = 0;
        let max = config::settlement_batch_max();
        while (i < max + 1) {
            vector::push_back(&mut traders, @0x1);
            i = i + 1;
        };
        settle_positions(series_id, traders);
    }
}
