/// The match loop: walks the opposite side of a series' book, price-time
/// priority first, filling against each resting order via `clearing` until
/// the taker is filled, the book runs out, prices stop crossing, or
/// `config::max_fills_per_order()` is hit. Whatever is left unfilled is
/// returned for `orders::place_order` to rest (GTC) or drop (IOC) - this
/// module never touches the taker's own side of the book.
module zero_day_futures::matching {
    use std::option;
    use zero_day_futures::clearing;
    use zero_day_futures::config;
    use zero_day_futures::events;
    use zero_day_futures::margin;
    use zero_day_futures::order_book;

    friend zero_day_futures::orders;

    /// Matches up to `taker_size` of `taker_side` for `taker` against
    /// `series_id`'s opposite side at `taker_price` or better, and returns
    /// however much remains unfilled.
    ///
    /// Aborts with `E_SELF_TRADE` the instant the best opposing order belongs
    /// to `taker` - per docs/spec/business-rules.md, a self-trade is refused
    /// outright, not skipped past to the next order.
    public(friend) fun match_against_book(
        taker: address,
        series_id: u64,
        taker_side: u8,
        taker_price: u64,
        taker_size: u64,
        reduce_only: bool,
    ): u64 {
        let opposite_side = other_side(taker_side);
        let remaining = taker_size;
        let fills = 0;

        while (remaining > 0 && fills < config::max_fills_per_order()) {
            let maybe_maker = order_book::best(series_id, opposite_side);
            if (option::is_none(&maybe_maker)) { break };
            let maker = option::extract(&mut maybe_maker);

            if (!is_marketable(taker_side, taker_price, order_book::price_of(&maker))) { break };
            assert!(order_book::trader_of(&maker) != taker, config::e_self_trade());

            let fill_size = min_u64(remaining, order_book::remaining_of(&maker));
            let fill_price = order_book::price_of(&maker);
            let maker_order_id = order_book::order_id_of(&maker);
            let maker_trader = order_book::trader_of(&maker);

            let maker_margin_delta = if (order_book::reduce_only_of(&maker)) {
                0
            } else {
                margin::initial_margin(fill_price, fill_size)
            };
            clearing::apply_fill(maker_trader, series_id, opposite_side, fill_price, fill_size, maker_margin_delta);

            let taker_margin_delta = if (reduce_only) { 0 } else {
                margin::initial_margin(taker_price, fill_size)
            };
            clearing::apply_fill(taker, series_id, taker_side, fill_price, fill_size, taker_margin_delta);

            events::emit_trade_executed(series_id, fill_price, fill_size, maker_trader, taker, taker_side);

            let maker_remaining_after = order_book::remaining_of(&maker) - fill_size;
            if (maker_remaining_after == 0) {
                order_book::remove(maker_order_id);
                events::emit_order_updated(maker_order_id, 0, order_book::order_status_filled());
            } else {
                order_book::reduce_remaining(maker_order_id, fill_size);
                events::emit_order_updated(maker_order_id, maker_remaining_after, order_book::order_status_partial());
            };

            remaining = remaining - fill_size;
            fills = fills + 1;
        };

        remaining
    }

    fun other_side(side: u8): u8 {
        if (side == margin::side_long()) { margin::side_short() } else { margin::side_long() }
    }

    /// True when a `taker_side` order at `taker_price` would cross a resting
    /// order at `maker_price`: a buy crosses any ask at or below its price, a
    /// sell crosses any bid at or above its price.
    fun is_marketable(taker_side: u8, taker_price: u64, maker_price: u64): bool {
        if (taker_side == margin::side_long()) { maker_price <= taker_price } else { maker_price >= taker_price }
    }

    fun min_u64(a: u64, b: u64): u64 { if (a < b) { a } else { b } }

    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use zero_day_futures::collateral;
    #[test_only]
    use zero_day_futures::position;
    #[test_only]
    use zero_day_futures::vault;

    #[test_only]
    const TEST_PRICE_UNIT: u64 = 1_000_000;
    #[test_only]
    const TEST_LOT_UNIT: u64 = 10_000;

    #[test_only]
    fun setup_for_test(deployer: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        collateral::init_module_for_test(deployer);
        vault::init_module_for_test(deployer);
        position::init_module_for_test(deployer);
        order_book::init_module_for_test(deployer);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, maker = @0xA, taker = @0xB)]
    fun test_taker_fully_fills_against_one_maker(
        deployer: &signer, aptos_framework: &signer, maker: &signer, taker: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        let price = 65_000 * TEST_PRICE_UNIT;
        order_book::insert(1, margin::side_short(), 1, signer::address_of(maker), price, TEST_LOT_UNIT, false);

        let remaining = match_against_book(
            signer::address_of(taker), 1, margin::side_long(), price, TEST_LOT_UNIT, false,
        );

        assert!(remaining == 0, 0);
        assert!(!order_book::exists_order(1), 1);
        let taker_position = position::get_position(signer::address_of(taker), 1);
        assert!(position::size_of(&taker_position) == TEST_LOT_UNIT, 2);
        let maker_position = position::get_position(signer::address_of(maker), 1);
        assert!(position::size_of(&maker_position) == TEST_LOT_UNIT, 3);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, maker = @0xA, taker = @0xB)]
    fun test_taker_partially_fills_and_returns_remainder(
        deployer: &signer, aptos_framework: &signer, maker: &signer, taker: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        let price = 65_000 * TEST_PRICE_UNIT;
        order_book::insert(1, margin::side_short(), 1, signer::address_of(maker), price, TEST_LOT_UNIT, false);

        let remaining = match_against_book(
            signer::address_of(taker), 1, margin::side_long(), price, 3 * TEST_LOT_UNIT, false,
        );

        assert!(remaining == 2 * TEST_LOT_UNIT, 0);
        assert!(!order_book::exists_order(1), 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, maker = @0xA, taker = @0xB)]
    fun test_maker_partially_filled_stays_resting(
        deployer: &signer, aptos_framework: &signer, maker: &signer, taker: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        let price = 65_000 * TEST_PRICE_UNIT;
        order_book::insert(1, margin::side_short(), 1, signer::address_of(maker), price, 5 * TEST_LOT_UNIT, false);

        let remaining = match_against_book(
            signer::address_of(taker), 1, margin::side_long(), price, 2 * TEST_LOT_UNIT, false,
        );

        assert!(remaining == 0, 0);
        assert!(order_book::exists_order(1), 1);
        let found = order_book::get_order(1);
        let order = option::extract(&mut found);
        assert!(order_book::remaining_of(&order) == 3 * TEST_LOT_UNIT, 2);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, taker = @0xB)]
    fun test_non_crossing_price_matches_nothing(
        deployer: &signer, aptos_framework: &signer, taker: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        order_book::insert(1, margin::side_short(), 1, @0xA, 70_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, false);

        // Taker's bid is below the resting ask - nothing should cross.
        let remaining = match_against_book(
            signer::address_of(taker), 1, margin::side_long(), 60_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, false,
        );

        assert!(remaining == TEST_LOT_UNIT, 0);
        assert!(order_book::exists_order(1), 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    #[expected_failure(abort_code = 7, location = Self)] // config::E_SELF_TRADE
    fun test_self_trade_aborts(deployer: &signer, aptos_framework: &signer, trader: &signer) {
        setup_for_test(deployer, aptos_framework);
        let price = 65_000 * TEST_PRICE_UNIT;
        order_book::insert(1, margin::side_short(), 1, signer::address_of(trader), price, TEST_LOT_UNIT, false);
        match_against_book(signer::address_of(trader), 1, margin::side_long(), price, TEST_LOT_UNIT, false);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, taker = @0xB)]
    fun test_fills_are_capped_per_order(deployer: &signer, aptos_framework: &signer, taker: &signer) {
        setup_for_test(deployer, aptos_framework);
        let price = 65_000 * TEST_PRICE_UNIT;
        let max_fills = config::max_fills_per_order();
        let i = 0;
        while (i < max_fills + 1) {
            order_book::insert(1, margin::side_short(), i + 1, @0xA, price, TEST_LOT_UNIT, false);
            i = i + 1;
        };

        let remaining = match_against_book(
            signer::address_of(taker), 1, margin::side_long(), price, (max_fills + 1) * TEST_LOT_UNIT, false,
        );

        // One maker order's worth is left unfilled - the cap stopped the loop
        // one fill short of fully consuming the book.
        assert!(remaining == TEST_LOT_UNIT, 0);
    }
}
