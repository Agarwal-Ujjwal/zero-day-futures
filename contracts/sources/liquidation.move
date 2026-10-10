/// `liquidate`: re-verifies the margin condition against the oracle price,
/// closes the position at that price against the insurance-fund backstop
/// account, and charges a penalty. Permissionless - anyone can call it (the
/// keeper does, in practice), because the condition is re-checked here from
/// the position and the oracle, not trusted from the caller.
///
/// The backstop absorbs the closed position (same side, same size, at index
/// price) so liquidation never needs book liquidity to find a real
/// counterparty - total open interest in the series doesn't change, only who
/// holds one side of it. The fund's backstop positions settle at expiry
/// through `@zero_day_futures`'s own vault free balance, like any other
/// trader's - which means trading gains on a backstop position are, in this
/// MVP, withdrawable by whoever holds the deployer/admin key. That's a
/// documented simplification, not an oversight: a production version would
/// keep backstop proceeds in a dedicated, non-withdrawable pool.
module zero_day_futures::liquidation {
    use zero_day_futures::clearing;
    use zero_day_futures::config;
    use zero_day_futures::events;
    use zero_day_futures::margin;
    use zero_day_futures::oracle;
    use zero_day_futures::position;
    use zero_day_futures::series;
    use zero_day_futures::vault;

    /// Checks `trader`'s position on `series_id` against the current index
    /// price and, if its equity is below the maintenance margin threshold,
    /// liquidates it: the insurance fund absorbs the position at the index
    /// price, a penalty is charged against the payout, and whatever is left
    /// returns to the trader's free balance.
    public entry fun liquidate(series_id: u64, trader: address) {
        let current = position::get_position(trader, series_id);
        assert!(position::is_open(&current), config::e_no_open_position());

        let (_underlying, pyth_feed_id, _expiry_ts, _is_settled, _settlement_price) = series::get_series(series_id);
        let (index_price, _posted_at) =
            oracle::get_price_no_older_than(pyth_feed_id, config::oracle_max_price_age_seconds());

        assert!(
            margin::is_liquidatable(
                position::margin_of(&current),
                position::entry_price_of(&current),
                index_price,
                position::size_of(&current),
                position::side_of(&current),
            ),
            config::e_position_healthy(),
        );

        let (side, size, gross_payout) = clearing::close_for_liquidation(trader, series_id, index_price);
        let penalty = margin::liquidation_penalty(index_price, size);
        let penalty_charged = if (penalty > gross_payout) { gross_payout } else { penalty };

        vault::unlock_margin(trader, gross_payout - penalty_charged);
        vault::credit_insurance_fund(penalty_charged);
        clearing::apply_fill(config::insurance_fund_address(), series_id, side, index_price, size, 0);

        events::emit_liquidated(trader, series_id, index_price, penalty_charged);
    }

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use zero_day_futures::collateral;
    #[test_only]
    use zero_day_futures::order_book;

    #[test_only]
    const TEST_PRICE_UNIT: u64 = 1_000_000;
    #[test_only]
    const TEST_LOT_UNIT: u64 = 10_000;

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
        series::create_series(deployer, btc, b"pyth-btc-feed", 86_400);
        series::get_latest_series_id(btc)
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_liquidate_closes_position_and_charges_penalty(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        let series_id = setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        let locked_margin = margin::initial_margin(entry, TEST_LOT_UNIT);
        clearing::apply_fill(trader_addr, series_id, margin::side_long(), entry, TEST_LOT_UNIT, locked_margin);

        // Price crashes far enough to wipe out the whole 10% margin.
        let crashed = 50_000 * TEST_PRICE_UNIT;
        oracle::post_price(deployer, b"pyth-btc-feed", crashed);

        liquidate(series_id, trader_addr);

        let closed = position::get_position(trader_addr, series_id);
        assert!(position::status_of(&closed) == position::status_liquidated(), 0);
        assert!(position::size_of(&closed) == 0, 1);
        assert!(position::margin_of(&closed) == 0, 2);

        let backstop = position::get_position(config::insurance_fund_address(), series_id);
        assert!(position::side_of(&backstop) == margin::side_long(), 3);
        assert!(position::size_of(&backstop) == TEST_LOT_UNIT, 4);
        assert!(position::entry_price_of(&backstop) == crashed, 5);

        // Fully wiped out: nothing left for a penalty, nothing left for the trader.
        assert!(vault::get_insurance_fund() == 0, 6);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    fun test_liquidate_charges_penalty_and_returns_remainder(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        let series_id = setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        let locked_margin = margin::initial_margin(entry, TEST_LOT_UNIT);
        clearing::apply_fill(trader_addr, series_id, margin::side_long(), entry, TEST_LOT_UNIT, locked_margin);

        // A drop that pushes equity under the 5% maintenance threshold while
        // leaving most of the margin intact (unlike the full-wipeout test).
        let dipped = 60_000 * TEST_PRICE_UNIT;
        oracle::post_price(deployer, b"pyth-btc-feed", dipped);
        assert!(
            margin::is_liquidatable(locked_margin, entry, dipped, TEST_LOT_UNIT, margin::side_long()), 0,
        );

        liquidate(series_id, trader_addr);

        let expected_penalty = margin::liquidation_penalty(dipped, TEST_LOT_UNIT);
        assert!(vault::get_insurance_fund() == expected_penalty, 1);
        let expected_payout = margin::settlement_payout(locked_margin, entry, dipped, TEST_LOT_UNIT, margin::side_long());
        assert!(vault::get_balance(trader_addr) == expected_payout - expected_penalty, 2);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    #[expected_failure(abort_code = 10, location = Self)] // config::E_POSITION_HEALTHY
    fun test_liquidate_rejects_a_healthy_position(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        let series_id = setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        clearing::apply_fill(
            trader_addr, series_id, margin::side_long(), entry, TEST_LOT_UNIT,
            margin::initial_margin(entry, TEST_LOT_UNIT),
        );
        oracle::post_price(deployer, b"pyth-btc-feed", entry); // unchanged, fully healthy

        liquidate(series_id, trader_addr);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xA)]
    #[expected_failure(abort_code = 16, location = Self)] // config::E_NO_OPEN_POSITION
    fun test_liquidate_rejects_no_position(deployer: &signer, aptos_framework: &signer, trader: &signer) {
        let series_id = setup_for_test(deployer, aptos_framework);
        liquidate(series_id, std::signer::address_of(trader));
    }
}
