/// Nets fills into positions, realizes PnL on the reduced portion, and lets a
/// trader top up margin. This is the one module that translates a fill (a
/// price and a size) into the position/margin/vault state those other modules
/// own - it has no storage of its own.
///
/// `apply_fill` is written to be called once per *participant* in a trade
/// (future `matching.move` calls it twice per match: once for the taker, once
/// for the maker), not once per trade. That is what lets it stay ignorant of
/// the order book entirely - it only ever sees "this trader got filled this
/// much, at this price, on this side."
module zero_day_futures::clearing {
    use zero_day_futures::config;
    use zero_day_futures::events;
    use zero_day_futures::margin;
    use zero_day_futures::position::{Self, Position};
    use zero_day_futures::vault;

    friend zero_day_futures::matching;

    /// Applies one fill to `trader`'s position on `series_id`.
    ///
    /// `margin_delta` is collateral already locked by `orders::place_order` at
    /// order-placement time, now being attributed to the position this fill
    /// produces or grows - this function does not move any funds for it. It
    /// must be 0 when the fill reduces or closes the position, since
    /// reduce-only orders never lock margin in the first place (there is
    /// nothing to attribute); this is asserted, not silently ignored.
    ///
    /// Aborts with `E_POSITION_FLIP_NOT_ALLOWED` if `fill_size` would flip the
    /// position to the other side in one fill - the order book must never
    /// generate a fill like that (docs/spec/business-rules.md: no flipping).
    public(friend) fun apply_fill(
        trader: address,
        series_id: u64,
        fill_side: u8,
        fill_price: u64,
        fill_size: u64,
        margin_delta: u64,
    ) {
        let current = position::get_position(trader, series_id);
        let current_size = position::size_of(&current);

        let next = if (current_size == 0 || position::side_of(&current) == fill_side) {
            open_or_increase(&current, fill_side, fill_price, fill_size, margin_delta)
        } else {
            assert!(fill_size <= current_size, config::e_position_flip_not_allowed());
            assert!(margin_delta == 0, config::e_position_flip_not_allowed());
            reduce_or_close(trader, &current, fill_price, fill_size)
        };

        position::upsert_position(trader, series_id, next);
        emit_position_updated(series_id, trader, &next, position::reason_fill());
    }

    /// Moves `amount` from the caller's vault free balance into their open
    /// position's margin - the on-chain side of the margin-call "Add margin"
    /// button.
    public entry fun add_margin(account: &signer, series_id: u64, amount: u64) {
        let trader = std::signer::address_of(account);
        let current = position::get_position(trader, series_id);
        assert!(position::is_open(&current), config::e_no_open_position());

        vault::lock_margin(trader, amount);
        let (pnl_is_negative, pnl_magnitude) = position::realized_pnl_of(&current);
        let next = position::new_position(
            position::side_of(&current),
            position::size_of(&current),
            position::entry_price_of(&current),
            position::margin_of(&current) + amount,
            pnl_is_negative,
            pnl_magnitude,
            position::status_of(&current),
        );
        position::upsert_position(trader, series_id, next);
        emit_position_updated(series_id, trader, &next, position::reason_add_margin());
    }

    /// Opening a flat position, or increasing one on the same side: size adds
    /// up, entry price becomes the size-weighted average of the old and new
    /// fills, and `margin_delta` (already locked by `orders`) is attributed in.
    fun open_or_increase(
        current: &Position, fill_side: u8, fill_price: u64, fill_size: u64, margin_delta: u64,
    ): Position {
        let current_size = position::size_of(current);
        let new_size = current_size + fill_size;
        let new_entry_price = (
            ((position::entry_price_of(current) as u128) * (current_size as u128)
                + (fill_price as u128) * (fill_size as u128))
                / (new_size as u128)
        ) as u64;
        let (pnl_is_negative, pnl_magnitude) = position::realized_pnl_of(current);

        position::new_position(
            fill_side,
            new_size,
            new_entry_price,
            position::margin_of(current) + margin_delta,
            pnl_is_negative,
            pnl_magnitude,
            position::status_open(),
        )
    }

    /// Reducing or fully closing a position: entry price is unchanged (it only
    /// moves when a position grows), the closed share of PnL is realized and
    /// folded into the position's running total, and the margin apportioned to
    /// that share - adjusted for the PnL on it, floored at zero - is released
    /// to the trader's free balance. A per-fill loss that exceeds the margin
    /// apportioned to just this fill is floored rather than drawn from the
    /// position's remaining margin; this is a deliberate simplification; see
    /// docs/spec/business-rules.md's "bad debt" note for the analogous
    /// settlement-side tradeoff.
    fun reduce_or_close(trader: address, current: &Position, fill_price: u64, fill_size: u64): Position {
        let current_size = position::size_of(current);
        let current_margin = position::margin_of(current);
        let side = position::side_of(current);
        let entry_price = position::entry_price_of(current);

        let margin_share = (((current_margin as u128) * (fill_size as u128)) / (current_size as u128)) as u64;
        let (fill_is_loss, fill_pnl_magnitude) = margin::pnl(entry_price, fill_price, fill_size, side);
        let payout = if (fill_is_loss) {
            if (fill_pnl_magnitude <= margin_share) { margin_share - fill_pnl_magnitude } else { 0 }
        } else {
            margin_share + fill_pnl_magnitude
        };
        vault::unlock_margin(trader, payout);

        let (old_pnl_is_negative, old_pnl_magnitude) = position::realized_pnl_of(current);
        let (new_pnl_is_negative, new_pnl_magnitude) =
            margin::combine_signed(old_pnl_is_negative, old_pnl_magnitude, fill_is_loss, fill_pnl_magnitude);

        let new_size = current_size - fill_size;
        let status = if (new_size == 0) { position::status_closed() } else { position::status_open() };

        position::new_position(
            side, new_size, entry_price, current_margin - margin_share,
            new_pnl_is_negative, new_pnl_magnitude, status,
        )
    }

    fun emit_position_updated(series_id: u64, trader: address, position: &Position, reason: u8) {
        let (pnl_is_negative, pnl_magnitude) = position::realized_pnl_of(position);
        events::emit_position_updated(
            series_id,
            trader,
            position::side_of(position),
            position::size_of(position),
            position::entry_price_of(position),
            position::margin_of(position),
            pnl_is_negative,
            pnl_magnitude,
            reason,
        );
    }

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use zero_day_futures::collateral;
    #[test_only]
    use zero_day_futures::margin as margin_consts;

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
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xCAFE)]
    fun test_apply_fill_opens_a_position(deployer: &signer, aptos_framework: &signer, trader: &signer) {
        setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let price = 65_000 * TEST_PRICE_UNIT;
        let size = TEST_LOT_UNIT;
        let margin_locked = margin_consts::initial_margin(price, size);

        apply_fill(trader_addr, 1, margin_consts::side_long(), price, size, margin_locked);

        let opened = position::get_position(trader_addr, 1);
        assert!(position::is_open(&opened), 0);
        assert!(position::size_of(&opened) == size, 1);
        assert!(position::entry_price_of(&opened) == price, 2);
        assert!(position::margin_of(&opened) == margin_locked, 3);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xCAFE)]
    fun test_apply_fill_increase_averages_entry_price(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let long = margin_consts::side_long();

        apply_fill(trader_addr, 1, long, 60_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT,
            margin_consts::initial_margin(60_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT));
        apply_fill(trader_addr, 1, long, 70_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT,
            margin_consts::initial_margin(70_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT));

        let grown = position::get_position(trader_addr, 1);
        assert!(position::size_of(&grown) == 2 * TEST_LOT_UNIT, 0);
        assert!(position::entry_price_of(&grown) == 65_000 * TEST_PRICE_UNIT, 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xCAFE)]
    fun test_apply_fill_fully_closes_a_winning_long(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        let margin_locked = margin_consts::initial_margin(entry, TEST_LOT_UNIT);
        apply_fill(trader_addr, 1, margin_consts::side_long(), entry, TEST_LOT_UNIT, margin_locked);
        apply_fill(trader_addr, 1, margin_consts::side_short(), 70_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT, 0);

        let closed = position::get_position(trader_addr, 1);
        assert!(position::status_of(&closed) == position::status_closed(), 0);
        assert!(position::size_of(&closed) == 0, 1);
        assert!(position::margin_of(&closed) == 0, 2);
        let (is_negative, magnitude) = position::realized_pnl_of(&closed);
        assert!(!is_negative, 3);
        assert!(magnitude == 5_000 * TEST_PRICE_UNIT, 4);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xCAFE)]
    #[expected_failure(abort_code = 4, location = Self)] // config::E_POSITION_FLIP_NOT_ALLOWED
    fun test_apply_fill_rejects_a_flip(deployer: &signer, aptos_framework: &signer, trader: &signer) {
        setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        apply_fill(
            trader_addr, 1, margin_consts::side_long(), entry, TEST_LOT_UNIT,
            margin_consts::initial_margin(entry, TEST_LOT_UNIT),
        );
        apply_fill(trader_addr, 1, margin_consts::side_short(), entry, 2 * TEST_LOT_UNIT, 0);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xCAFE)]
    fun test_add_margin_increases_position_margin(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        let trader_addr = std::signer::address_of(trader);
        let entry = 65_000 * TEST_PRICE_UNIT;
        let initial = margin_consts::initial_margin(entry, TEST_LOT_UNIT);
        apply_fill(trader_addr, 1, margin_consts::side_long(), entry, TEST_LOT_UNIT, initial);

        collateral::faucet_mint(trader);
        vault::deposit(trader, collateral::faucet_claim_amount());
        add_margin(trader, 1, 1_000_000);

        let topped_up = position::get_position(trader_addr, 1);
        assert!(position::margin_of(&topped_up) == initial + 1_000_000, 0);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, trader = @0xCAFE)]
    #[expected_failure(abort_code = 16, location = Self)] // config::E_NO_OPEN_POSITION
    fun test_add_margin_requires_open_position(
        deployer: &signer, aptos_framework: &signer, trader: &signer,
    ) {
        setup_for_test(deployer, aptos_framework);
        add_margin(trader, 1, 100);
    }
}
