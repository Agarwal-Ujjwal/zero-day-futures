/// Shared constants, risk parameters and the admin capability for the whole package.
/// Every other module reads units and abort codes from here instead of hardcoding
/// them, so there is exactly one place to change a rate or add an error case.
/// See docs/spec/units.md and docs/spec/abort-codes.md for the mirrored TypeScript
/// side of this contract.
module zero_day_futures::config {
    use std::signer;

    // ---------------------------------------------------------------------
    // Units (docs/spec/units.md)
    // ---------------------------------------------------------------------

    /// 1 unit of USD price = 1_000_000 (6 decimals), e.g. $65,000.00 = 65_000_000000.
    const PRICE_UNIT: u64 = 1_000_000;

    /// Size is stored in lots; 1 lot = 0.0001 of the underlying.
    const LOT_UNIT: u64 = 10_000;

    /// Mock USDC collateral also uses 6 decimals, matching real USDC.
    const COLLATERAL_DECIMALS: u8 = 6;

    // ---------------------------------------------------------------------
    // Risk parameters, expressed in basis points (1 bps = 0.01%) so they are
    // exact integers rather than floats.
    // ---------------------------------------------------------------------

    const BPS_DENOMINATOR: u64 = 10_000;
    const MAX_LEVERAGE: u64 = 10;
    const INITIAL_MARGIN_BPS: u64 = 1_000; // 10% of notional, locked at order placement
    const MAINTENANCE_MARGIN_BPS: u64 = 500; // 5% of notional, the liquidation threshold
    const LIQUIDATION_PENALTY_BPS: u64 = 100; // 1% of notional, paid to the insurance fund

    /// Maximum traders settled per `settle_positions` call, so a series with many
    /// open positions never needs a single transaction to iterate over all of them.
    const SETTLEMENT_BATCH_MAX: u64 = 25;

    /// Default series lifetime. The n-day extension changes the argument passed to
    /// `series::create_series`, not this constant.
    const SERIES_DURATION_SECONDS: u64 = 86_400;

    /// Caps on order-book usage per transaction / per account, so neither a
    /// single match nor a single account's resting orders can make a
    /// transaction's gas cost unbounded.
    const MAX_FILLS_PER_ORDER: u64 = 10;
    const MAX_OPEN_ORDERS_PER_SERIES: u64 = 20;

    /// Default staleness bound for a keeper-posted oracle price (see
    /// `oracle.move` - Pyth no longer supports Aptos, so this project's index
    /// price is posted on-chain by the keeper instead of pulled from a
    /// cross-chain attestation). A bit more than one keeper tick interval.
    const ORACLE_MAX_PRICE_AGE_SECONDS: u64 = 90;

    // ---------------------------------------------------------------------
    // Abort codes (docs/spec/abort-codes.md) - grouped by the module that raises
    // them. Keep this list and the mirrored map in src/lib/chain/errors.ts in sync.
    // ---------------------------------------------------------------------

    const E_NOT_ADMIN: u64 = 1;
    const E_INSUFFICIENT_FREE_BALANCE: u64 = 2;
    const E_REDUCE_ONLY_VIOLATION: u64 = 3;
    const E_POSITION_FLIP_NOT_ALLOWED: u64 = 4;
    const E_SERIES_EXPIRED: u64 = 5;
    const E_SERIES_NOT_EXPIRED: u64 = 6;
    const E_SELF_TRADE: u64 = 7;
    const E_ORACLE_PRICE_STALE: u64 = 8;
    const E_SETTLEMENT_PRICE_TOO_EARLY: u64 = 9;
    const E_POSITION_HEALTHY: u64 = 10;
    const E_BATCH_TOO_LARGE: u64 = 11;
    const E_OPEN_ORDER_CAP_EXCEEDED: u64 = 12;
    const E_FILLS_CAP_EXCEEDED: u64 = 13;
    const E_FAUCET_COOLDOWN: u64 = 14;
    const E_UNDERLYING_NOT_REGISTERED: u64 = 15;
    const E_NO_OPEN_POSITION: u64 = 16;
    const E_ORDER_NOT_FOUND: u64 = 17;
    const E_NOT_ORDER_OWNER: u64 = 18;
    const E_NOT_KEEPER: u64 = 19;

    // ---------------------------------------------------------------------
    // Admin capability
    // ---------------------------------------------------------------------

    /// Proof that the holder is the package admin. It is a resource, not a value
    /// that can be copied or passed off-chain: only this module can move it into
    /// or out of storage, and only the account it is published under will ever
    /// hold one in this package's deployment.
    struct AdminCap has key {}

    /// Runs automatically once, at publish time, and grants the admin capability
    /// to whichever account published the package.
    fun init_module(deployer: &signer) {
        move_to(deployer, AdminCap {});
    }

    /// Aborts with `E_NOT_ADMIN` unless `account` holds the admin capability.
    public fun assert_is_admin(account: &signer) {
        assert!(exists<AdminCap>(signer::address_of(account)), E_NOT_ADMIN);
    }

    #[test_only]
    /// Other modules' tests need the admin capability granted too, but
    /// `init_module` itself is private (the framework calls it automatically
    /// at publish time on real networks, which never happens in a unit test).
    public fun init_module_for_test(deployer: &signer) {
        init_module(deployer);
    }

    // ---------------------------------------------------------------------
    // Getters - Move constants are private to their module, so every value
    // another module needs is exposed through one of these instead.
    // ---------------------------------------------------------------------

    /// The insurance fund's identity as a position-table "trader" - there is
    /// no real account behind it, so it borrows the package's own address.
    /// Backstop positions absorbed from liquidations settle through this
    /// address like any other trader's at expiry (docs/spec/business-rules.md).
    public fun insurance_fund_address(): address { @zero_day_futures }

    public fun price_unit(): u64 { PRICE_UNIT }
    public fun lot_unit(): u64 { LOT_UNIT }
    public fun collateral_decimals(): u8 { COLLATERAL_DECIMALS }

    public fun bps_denominator(): u64 { BPS_DENOMINATOR }
    public fun max_leverage(): u64 { MAX_LEVERAGE }
    public fun initial_margin_bps(): u64 { INITIAL_MARGIN_BPS }
    public fun maintenance_margin_bps(): u64 { MAINTENANCE_MARGIN_BPS }
    public fun liquidation_penalty_bps(): u64 { LIQUIDATION_PENALTY_BPS }
    public fun settlement_batch_max(): u64 { SETTLEMENT_BATCH_MAX }
    public fun series_duration_seconds(): u64 { SERIES_DURATION_SECONDS }
    public fun max_fills_per_order(): u64 { MAX_FILLS_PER_ORDER }
    public fun max_open_orders_per_series(): u64 { MAX_OPEN_ORDERS_PER_SERIES }
    public fun oracle_max_price_age_seconds(): u64 { ORACLE_MAX_PRICE_AGE_SECONDS }

    public fun e_not_admin(): u64 { E_NOT_ADMIN }
    public fun e_insufficient_free_balance(): u64 { E_INSUFFICIENT_FREE_BALANCE }
    public fun e_reduce_only_violation(): u64 { E_REDUCE_ONLY_VIOLATION }
    public fun e_position_flip_not_allowed(): u64 { E_POSITION_FLIP_NOT_ALLOWED }
    public fun e_series_expired(): u64 { E_SERIES_EXPIRED }
    public fun e_series_not_expired(): u64 { E_SERIES_NOT_EXPIRED }
    public fun e_self_trade(): u64 { E_SELF_TRADE }
    public fun e_oracle_price_stale(): u64 { E_ORACLE_PRICE_STALE }
    public fun e_settlement_price_too_early(): u64 { E_SETTLEMENT_PRICE_TOO_EARLY }
    public fun e_position_healthy(): u64 { E_POSITION_HEALTHY }
    public fun e_batch_too_large(): u64 { E_BATCH_TOO_LARGE }
    public fun e_open_order_cap_exceeded(): u64 { E_OPEN_ORDER_CAP_EXCEEDED }
    public fun e_fills_cap_exceeded(): u64 { E_FILLS_CAP_EXCEEDED }
    public fun e_faucet_cooldown(): u64 { E_FAUCET_COOLDOWN }
    public fun e_underlying_not_registered(): u64 { E_UNDERLYING_NOT_REGISTERED }
    public fun e_no_open_position(): u64 { E_NO_OPEN_POSITION }
    public fun e_order_not_found(): u64 { E_ORDER_NOT_FOUND }
    public fun e_not_order_owner(): u64 { E_NOT_ORDER_OWNER }
    public fun e_not_keeper(): u64 { E_NOT_KEEPER }

    #[test(deployer = @zero_day_futures)]
    fun test_init_grants_admin_cap(deployer: &signer) {
        init_module(deployer);
        assert_is_admin(deployer);
    }

    #[test(deployer = @zero_day_futures, not_admin = @0xB0B)]
    #[expected_failure(abort_code = E_NOT_ADMIN)]
    fun test_non_admin_rejected(deployer: &signer, not_admin: &signer) {
        init_module(deployer);
        assert_is_admin(not_admin);
    }
}
