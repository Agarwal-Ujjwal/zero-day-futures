/// Pure margin and PnL math, with no storage of its own. Mirrors
/// docs/spec/business-rules.md exactly, so the TS math in src/lib/math can be
/// checked against it line for line - though the contract, not that mirror, is
/// always the authority for anything that actually moves funds.
module zero_day_futures::margin {
    use zero_day_futures::config;

    /// Position/order side. Move has no native enum, so a `u8` with named
    /// constants is used everywhere a side is needed - orders, positions, here.
    const SIDE_LONG: u8 = 0;
    const SIDE_SHORT: u8 = 1;

    public fun side_long(): u8 { SIDE_LONG }
    public fun side_short(): u8 { SIDE_SHORT }

    /// Notional value of `size` lots at `price`, in the same 6-decimal USD unit
    /// as `price` itself. Uses a u128 intermediate so a large price times a
    /// large size cannot silently wrap before narrowing back to u64.
    public fun notional(price: u64, size: u64): u64 {
        (((price as u128) * (size as u128)) / (config::lot_unit() as u128) as u64)
    }

    /// Initial margin required to open `size` at `price`: `initial_margin_bps`
    /// of the notional.
    public fun initial_margin(price: u64, size: u64): u64 {
        bps_of(notional(price, size), config::initial_margin_bps())
    }

    /// Maintenance margin threshold for `size` valued at `index_price`:
    /// `maintenance_margin_bps` of the notional at the index price.
    public fun maintenance_margin(index_price: u64, size: u64): u64 {
        bps_of(notional(index_price, size), config::maintenance_margin_bps())
    }

    /// Liquidation penalty on `size` valued at `index_price`:
    /// `liquidation_penalty_bps` of the notional at the index price.
    public fun liquidation_penalty(index_price: u64, size: u64): u64 {
        bps_of(notional(index_price, size), config::liquidation_penalty_bps())
    }

    /// Unrealized PnL for a position of `size` opened at `entry_price`, marked
    /// at `mark_price`, as `(is_loss, magnitude)`. A long gains when
    /// `mark_price > entry_price`; a short gains when it falls - there is no
    /// signed integer type in Move, so sign and magnitude travel separately.
    public fun pnl(entry_price: u64, mark_price: u64, size: u64, side: u8): (bool, u64) {
        let (price_fell, price_diff) = if (mark_price >= entry_price) {
            (false, mark_price - entry_price)
        } else {
            (true, entry_price - mark_price)
        };
        let magnitude = notional(price_diff, size);
        let is_loss = if (side == SIDE_LONG) { price_fell } else { !price_fell };
        (is_loss, magnitude)
    }

    /// Position equity (`margin + PnL`, sign flipped for shorts, per
    /// docs/spec/business-rules.md) as `(is_negative, magnitude)`.
    public fun equity(
        margin: u64, entry_price: u64, mark_price: u64, size: u64, side: u8,
    ): (bool, u64) {
        let (pnl_is_loss, pnl_magnitude) = pnl(entry_price, mark_price, size, side);
        if (pnl_is_loss) {
            if (pnl_magnitude <= margin) {
                (false, margin - pnl_magnitude)
            } else {
                (true, pnl_magnitude - margin)
            }
        } else {
            (false, margin + pnl_magnitude)
        }
    }

    /// True once equity falls below the maintenance margin threshold at
    /// `mark_price` - the condition `liquidation::liquidate` re-checks on-chain
    /// before closing a position.
    public fun is_liquidatable(
        margin: u64, entry_price: u64, mark_price: u64, size: u64, side: u8,
    ): bool {
        let (equity_is_negative, equity_magnitude) = equity(margin, entry_price, mark_price, size, side);
        equity_is_negative || equity_magnitude < maintenance_margin(mark_price, size)
    }

    /// Settlement payout: `max(0, margin + PnL)` at the settlement price. A
    /// negative result is not represented here - `settlement.move` draws the
    /// shortfall from the insurance fund and records any remainder as bad debt.
    public fun settlement_payout(
        margin: u64, entry_price: u64, settlement_price: u64, size: u64, side: u8,
    ): u64 {
        let (equity_is_negative, equity_magnitude) = equity(margin, entry_price, settlement_price, size, side);
        if (equity_is_negative) { 0 } else { equity_magnitude }
    }

    fun bps_of(amount: u64, bps: u64): u64 {
        (((amount as u128) * (bps as u128)) / (config::bps_denominator() as u128) as u64)
    }

    #[test_only]
    const TEST_PRICE_UNIT: u64 = 1_000_000;
    #[test_only]
    const TEST_LOT_UNIT: u64 = 10_000;

    #[test]
    fun test_notional_one_unit_at_65k() {
        let price = 65_000 * TEST_PRICE_UNIT;
        let size = TEST_LOT_UNIT; // 1.0 underlying
        assert!(notional(price, size) == price, 0);
    }

    #[test]
    fun test_initial_margin_is_ten_percent_of_notional() {
        let price = 65_000 * TEST_PRICE_UNIT;
        let size = TEST_LOT_UNIT;
        assert!(initial_margin(price, size) == price / 10, 0);
    }

    #[test]
    fun test_long_gains_when_price_rises() {
        let entry = 65_000 * TEST_PRICE_UNIT;
        let mark = 70_000 * TEST_PRICE_UNIT;
        let (is_loss, magnitude) = pnl(entry, mark, TEST_LOT_UNIT, SIDE_LONG);
        assert!(!is_loss, 0);
        assert!(magnitude == 5_000 * TEST_PRICE_UNIT, 1);
    }

    #[test]
    fun test_short_gains_when_price_falls() {
        let entry = 65_000 * TEST_PRICE_UNIT;
        let mark = 60_000 * TEST_PRICE_UNIT;
        let (is_loss, magnitude) = pnl(entry, mark, TEST_LOT_UNIT, SIDE_SHORT);
        assert!(!is_loss, 0);
        assert!(magnitude == 5_000 * TEST_PRICE_UNIT, 1);
    }

    #[test]
    fun test_short_loses_when_price_rises() {
        let entry = 65_000 * TEST_PRICE_UNIT;
        let mark = 70_000 * TEST_PRICE_UNIT;
        let (is_loss, magnitude) = pnl(entry, mark, TEST_LOT_UNIT, SIDE_SHORT);
        assert!(is_loss, 0);
        assert!(magnitude == 5_000 * TEST_PRICE_UNIT, 1);
    }

    #[test]
    fun test_equity_reflects_loss_against_margin() {
        let margin_amount = initial_margin(65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT); // 6_500 * unit
        let entry = 65_000 * TEST_PRICE_UNIT;
        let mark = 50_000 * TEST_PRICE_UNIT; // long loses 15_000 * unit
        let (is_negative, magnitude) = equity(margin_amount, entry, mark, TEST_LOT_UNIT, SIDE_LONG);
        assert!(is_negative, 0);
        assert!(magnitude == 15_000 * TEST_PRICE_UNIT - margin_amount, 1);
    }

    #[test]
    fun test_is_liquidatable_true_when_equity_wiped_out() {
        let margin_amount = initial_margin(65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT);
        let entry = 65_000 * TEST_PRICE_UNIT;
        let mark = 50_000 * TEST_PRICE_UNIT;
        assert!(is_liquidatable(margin_amount, entry, mark, TEST_LOT_UNIT, SIDE_LONG), 0);
    }

    #[test]
    fun test_is_liquidatable_false_when_healthy() {
        let margin_amount = initial_margin(65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT);
        let entry = 65_000 * TEST_PRICE_UNIT;
        let mark = 65_000 * TEST_PRICE_UNIT; // unchanged, fully healthy
        assert!(!is_liquidatable(margin_amount, entry, mark, TEST_LOT_UNIT, SIDE_LONG), 0);
    }

    #[test]
    fun test_settlement_payout_floors_at_zero() {
        let margin_amount = initial_margin(65_000 * TEST_PRICE_UNIT, TEST_LOT_UNIT); // 6_500 * unit
        let entry = 65_000 * TEST_PRICE_UNIT;
        let settlement = 50_000 * TEST_PRICE_UNIT; // loss of 15_000 * unit, far exceeds margin
        assert!(settlement_payout(margin_amount, entry, settlement, TEST_LOT_UNIT, SIDE_LONG) == 0, 0);
    }
}
