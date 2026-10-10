/// The `place_order`/`cancel_order` entry points: the only way a trader's
/// limit order reaches the book. Validates the series and the reduce-only
/// constraint, locks initial margin, hands off to `matching`, and either
/// rests or drops whatever is left over.
module zero_day_futures::orders {
    use std::option;
    use std::signer;
    use zero_day_futures::config;
    use zero_day_futures::events;
    use zero_day_futures::margin;
    use zero_day_futures::matching;
    use zero_day_futures::order_book;
    use zero_day_futures::position;
    use zero_day_futures::series;
    use zero_day_futures::vault;

    /// Time in force. There is no separate "market order" type on-chain - a
    /// market order is just an IOC order with a deliberately generous `price`
    /// as a slippage bound, chosen by the client.
    const TIF_GTC: u8 = 0;
    const TIF_IOC: u8 = 1;

    public fun tif_gtc(): u8 { TIF_GTC }
    public fun tif_ioc(): u8 { TIF_IOC }

    struct NextOrderId has key {
        value: u64,
    }

    /// Runs once at publish time. Order ids start at 1.
    fun init_module(deployer: &signer) {
        move_to(deployer, NextOrderId { value: 1 });
    }

    fun next_order_id(): u64 acquires NextOrderId {
        let state = borrow_global_mut<NextOrderId>(@zero_day_futures);
        let id = state.value;
        state.value = id + 1;
        id
    }

    /// Places a limit order on `series_id`. A non-reduce-only order locks
    /// `margin::initial_margin(price, size)` up front; a reduce-only order
    /// locks nothing, since it can only ever shrink a position the trader
    /// already has margin behind. Matches immediately against the opposite
    /// side of the book, then for `tif_gtc()` rests whatever didn't fill, or
    /// for `tif_ioc()` drops it and releases its share of locked margin.
    public entry fun place_order(
        account: &signer,
        series_id: u64,
        side: u8,
        price: u64,
        size: u64,
        tif: u8,
        reduce_only: bool,
    ) acquires NextOrderId {
        let trader = signer::address_of(account);
        assert!(!series::is_expired(series_id), config::e_series_expired());

        if (reduce_only) {
            assert_reduce_only_is_valid(trader, series_id, side, size);
        } else {
            vault::lock_margin(trader, margin::initial_margin(price, size));
        };

        let remaining = matching::match_against_book(trader, series_id, side, price, size, reduce_only);
        let order_id = next_order_id();
        events::emit_order_placed(order_id, series_id, trader, side, price, size, remaining, tif, reduce_only);

        if (remaining > 0) {
            if (tif == TIF_GTC) {
                order_book::insert(series_id, side, order_id, trader, price, remaining, reduce_only);
            } else if (!reduce_only) {
                // IOC: whatever didn't fill is dropped. Margin scales
                // linearly with size, so exactly `remaining`'s share of what
                // was locked for the full order is left to return here - the
                // rest was already attributed to fills by `matching`.
                vault::unlock_margin(trader, margin::initial_margin(price, remaining));
            };
        };
    }

    fun assert_reduce_only_is_valid(trader: address, series_id: u64, side: u8, size: u64) {
        let current = position::get_position(trader, series_id);
        let opposite_of_current = if (position::side_of(&current) == margin::side_long()) {
            margin::side_short()
        } else {
            margin::side_long()
        };
        assert!(
            position::is_open(&current) && side == opposite_of_current && size <= position::size_of(&current),
            config::e_reduce_only_violation(),
        );
    }

    /// Cancels a resting order, releasing whatever share of its originally
    /// locked margin was never filled (none, if it was reduce-only). Only the
    /// order's own trader may cancel while its series is still open; once a
    /// series expires, anyone may, so an abandoned order can't trap a
    /// trader's margin forever.
    public entry fun cancel_order(account: &signer, order_id: u64) {
        let caller = signer::address_of(account);
        let found = order_book::get_order(order_id);
        assert!(option::is_some(&found), config::e_order_not_found());
        let order = option::extract(&mut found);
        let series_id = order_book::series_id_of_order(order_id);

        if (!series::is_expired(series_id)) {
            assert!(order_book::trader_of(&order) == caller, config::e_not_order_owner());
        };

        order_book::remove(order_id);
        if (!order_book::reduce_only_of(&order)) {
            vault::unlock_margin(
                order_book::trader_of(&order),
                margin::initial_margin(order_book::price_of(&order), order_book::remaining_of(&order)),
            );
        };
        events::emit_order_updated(order_id, 0, order_book::order_status_cancelled());
    }

    #[test_only]
    public fun init_module_for_test(deployer: &signer) {
        init_module(deployer);
    }

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use zero_day_futures::collateral;

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
        series::init_module_for_test(deployer);
        init_module_for_test(deployer);
    }

    #[test_only]
    fun fund_account(trader: &signer, amount: u64) {
        collateral::faucet_mint(trader);
        vault::deposit(trader, amount);
    }

    #[test_only]
    fun open_series(deployer: &signer): u64 {
        config::init_module_for_test(deployer);
        let btc = std::string::utf8(b"BTC");
        series::add_underlying(deployer, btc, b"pyth-btc-feed");
        series::create_series(deployer, btc, b"pyth-btc-feed", 86_400);
        series::get_latest_series_id(btc)
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_place_order_rests_when_book_is_empty(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(trader, collateral::faucet_claim_amount());

        place_order(trader, series_id, margin::side_long(), 65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, TIF_GTC, false);

        assert!(order_book::exists_order(1), 0);
        let locked_margin = margin::initial_margin(65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT);
        assert!(
            vault::get_balance(signer::address_of(trader)) == collateral::faucet_claim_amount() - locked_margin,
            1,
        );
    }

    #[test(
        deployer = @zero_day_futures, aptos_framework = @aptos_framework, maker = @0xA, taker = @0xB,
    )]
    fun test_place_order_matches_against_resting_maker(
        deployer: &signer, aptos_framework: &signer, maker: &signer, taker: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(maker, collateral::faucet_claim_amount());
        fund_account(taker, collateral::faucet_claim_amount());
        let price = 65_000 * TEST_PRICE_UNIT;

        place_order(maker, series_id, margin::side_short(), price, TEST_LOT_UNIT, TIF_GTC, false);
        place_order(taker, series_id, margin::side_long(), price, TEST_LOT_UNIT, TIF_GTC, false);

        assert!(!order_book::exists_order(1), 0); // maker's order was fully consumed
        let taker_position = position::get_position(signer::address_of(taker), series_id);
        assert!(position::size_of(&taker_position) == TEST_LOT_UNIT, 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_ioc_leftover_releases_margin_instead_of_resting(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(trader, collateral::faucet_claim_amount());

        place_order(trader, series_id, margin::side_long(), 65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, TIF_IOC, false);

        assert!(!order_book::exists_order(1), 0);
        assert!(vault::get_balance(signer::address_of(trader)) == collateral::faucet_claim_amount(), 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    #[expected_failure(abort_code = 5, location = Self)] // config::E_SERIES_EXPIRED
    fun test_place_order_rejects_expired_series(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(trader, collateral::faucet_claim_amount());
        timestamp::fast_forward_seconds(86_400);

        place_order(trader, series_id, margin::side_long(), 65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, TIF_GTC, false);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_cancel_order_releases_locked_margin(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(trader, collateral::faucet_claim_amount());
        place_order(trader, series_id, margin::side_long(), 65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, TIF_GTC, false);

        cancel_order(trader, 1);

        assert!(!order_book::exists_order(1), 0);
        assert!(vault::get_balance(signer::address_of(trader)) == collateral::faucet_claim_amount(), 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA, stranger = @0xB)]
    #[expected_failure(abort_code = 18, location = Self)] // config::E_NOT_ORDER_OWNER
    fun test_cancel_order_requires_ownership_before_expiry(
        deployer: &signer, aptos_framework: &signer, trader: &signer, stranger: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(trader, collateral::faucet_claim_amount());
        place_order(trader, series_id, margin::side_long(), 65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, TIF_GTC, false);

        cancel_order(stranger, 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA, stranger = @0xB)]
    fun test_anyone_can_cancel_after_series_expires(
        deployer: &signer, aptos_framework: &signer, trader: &signer, stranger: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(trader, collateral::faucet_claim_amount());
        place_order(trader, series_id, margin::side_long(), 65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, TIF_GTC, false);
        timestamp::fast_forward_seconds(86_400);

        cancel_order(stranger, 1);
        assert!(!order_book::exists_order(1), 0);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    #[expected_failure(abort_code = 3, location = Self)] // config::E_REDUCE_ONLY_VIOLATION
    fun test_reduce_only_without_position_is_rejected(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) acquires NextOrderId {
        setup_for_test(deployer, aptos_framework);
        let series_id = open_series(deployer);
        fund_account(trader, collateral::faucet_claim_amount());
        place_order(trader, series_id, margin::side_short(), 65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, TIF_GTC, true);
    }
}
