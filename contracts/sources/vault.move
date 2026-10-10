/// Custody, free balance and the insurance fund. This is the only module that
/// moves real collateral tokens; every other module (orders, clearing,
/// liquidation, settlement) only edits the ledger here via the `friend` entry
/// points below. See docs/architecture.md Section 8: funds sit in a
/// module-controlled store whose signer capability never leaves this file.
module zero_day_futures::vault {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::fungible_asset::{Self, FungibleStore};
    use aptos_framework::primary_fungible_store;
    use zero_day_futures::collateral;
    use zero_day_futures::config;
    use zero_day_futures::events;

    friend zero_day_futures::clearing;
    friend zero_day_futures::orders;
    friend zero_day_futures::liquidation;
    friend zero_day_futures::settlement;

    /// Fixed seed for the named object that owns the pooled custody store, so its
    /// address can always be re-derived from `@zero_day_futures`.
    const VAULT_SEED: vector<u8> = b"zero_day_futures::vault";

    /// The vault object's own `ExtendRef`, stored under the object's address. Only
    /// this module can turn it into a signer, and only to move tokens out of the
    /// custody store below - never to act on a user's behalf anywhere else.
    struct VaultSigner has key {
        extend_ref: ExtendRef,
    }

    /// `custody_store` pools every depositor's mUSDC in a single FungibleStore.
    /// `free_balances` is the per-trader ledger of what each address can withdraw
    /// or use as order margin; locking/unlocking margin only edits this table, it
    /// never moves tokens. `insurance_fund` is the backstop balance drawn down by
    /// settlement shortfalls and topped up by liquidation penalties.
    struct Vault has key {
        custody_store: Object<FungibleStore>,
        free_balances: Table<address, u64>,
        insurance_fund: u64,
    }

    /// Runs once at publish time: creates the vault's own object (so it can hold a
    /// signer capability independent of any user account), opens its pooled
    /// custody store for mUSDC, and initializes an empty ledger.
    fun init_module(deployer: &signer) {
        let constructor_ref = object::create_named_object(deployer, VAULT_SEED);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let vault_object_signer = &object::generate_signer(&constructor_ref);
        let custody_store = fungible_asset::create_store(&constructor_ref, collateral::metadata());

        move_to(vault_object_signer, VaultSigner { extend_ref });
        move_to(deployer, Vault {
            custody_store,
            free_balances: table::new(),
            insurance_fund: 0,
        });
    }

    #[test_only]
    /// Other modules' tests need the vault initialized too, but `init_module`
    /// itself is private (the framework calls it automatically at publish time
    /// on real networks, which never happens inside a unit test).
    public fun init_module_for_test(deployer: &signer) {
        init_module(deployer);
    }

    fun vault_address(): address {
        let package_address = @zero_day_futures;
        object::create_object_address(&package_address, VAULT_SEED)
    }

    fun vault_signer(): signer acquires VaultSigner {
        let refs = borrow_global<VaultSigner>(vault_address());
        object::generate_signer_for_extending(&refs.extend_ref)
    }

    /// Move `amount` of mUSDC from the caller's own primary store into vault
    /// custody, crediting their free balance by the same amount.
    public entry fun deposit(account: &signer, amount: u64) acquires Vault {
        let depositor = signer::address_of(account);
        let fa = primary_fungible_store::withdraw(account, collateral::metadata(), amount);
        let vault = borrow_global_mut<Vault>(@zero_day_futures);
        fungible_asset::deposit(vault.custody_store, fa);
        credit_free(vault, depositor, amount);
        events::emit_deposited(depositor, amount);
    }

    /// Move `amount` of mUSDC from the caller's free balance back to their own
    /// primary store. Only free balance can be withdrawn - margin locked in open
    /// orders or positions is untouched and this call cannot reach it.
    public entry fun withdraw(account: &signer, amount: u64) acquires Vault, VaultSigner {
        let owner = signer::address_of(account);
        let vault = borrow_global_mut<Vault>(@zero_day_futures);
        debit_free(vault, owner, amount);
        let custody_store = vault.custody_store;
        let signer_for_vault = vault_signer();
        let fa = fungible_asset::withdraw(&signer_for_vault, custody_store, amount);
        primary_fungible_store::deposit(owner, fa);
        events::emit_withdrawn(owner, amount);
    }

    #[view]
    /// Current free (withdrawable / order-eligible) balance for `trader`. An
    /// address that has never deposited reads as zero rather than aborting.
    public fun get_balance(trader: address): u64 acquires Vault {
        balance_of(borrow_global<Vault>(@zero_day_futures), trader)
    }

    #[view]
    public fun get_insurance_fund(): u64 acquires Vault {
        borrow_global<Vault>(@zero_day_futures).insurance_fund
    }

    /// Ledger-only: moves `amount` out of `trader`'s free balance when an order is
    /// placed or margin is otherwise reserved. No tokens move; the amount is still
    /// inside the pooled custody store, just no longer counted as withdrawable.
    public(friend) fun lock_margin(trader: address, amount: u64) acquires Vault {
        debit_free(borrow_global_mut<Vault>(@zero_day_futures), trader, amount);
    }

    /// Ledger-only inverse of `lock_margin`, used on cancel, expiry release, or
    /// when a fill or settlement returns margin to free balance.
    public(friend) fun unlock_margin(trader: address, amount: u64) acquires Vault {
        credit_free(borrow_global_mut<Vault>(@zero_day_futures), trader, amount);
    }

    /// Adds `amount` to the insurance fund (e.g. a liquidation penalty).
    public(friend) fun credit_insurance_fund(amount: u64) acquires Vault {
        let vault = borrow_global_mut<Vault>(@zero_day_futures);
        vault.insurance_fund = vault.insurance_fund + amount;
    }

    /// Best-effort draw from the insurance fund: returns the actual amount drawn,
    /// which is `min(amount_requested, available)`. It never aborts, because a
    /// settlement shortfall larger than the fund is bad debt (docs/spec/
    /// business-rules.md), not a failed transaction - the caller is responsible
    /// for recording the difference.
    public(friend) fun draw_from_insurance_fund(amount_requested: u64): u64 acquires Vault {
        let vault = borrow_global_mut<Vault>(@zero_day_futures);
        let drawn = if (amount_requested > vault.insurance_fund) { vault.insurance_fund } else { amount_requested };
        vault.insurance_fund = vault.insurance_fund - drawn;
        drawn
    }

    fun balance_of(vault: &Vault, trader: address): u64 {
        if (table::contains(&vault.free_balances, trader)) {
            *table::borrow(&vault.free_balances, trader)
        } else {
            0
        }
    }

    fun credit_free(vault: &mut Vault, trader: address, amount: u64) {
        let current = balance_of(vault, trader);
        table::upsert(&mut vault.free_balances, trader, current + amount);
    }

    fun debit_free(vault: &mut Vault, trader: address, amount: u64) {
        let current = balance_of(vault, trader);
        assert!(current >= amount, config::e_insufficient_free_balance());
        table::upsert(&mut vault.free_balances, trader, current - amount);
    }

    #[test_only]
    use aptos_framework::timestamp;

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, user = @0xCAFE)]
    fun test_deposit_then_withdraw_round_trips(
        deployer: &signer, aptos_framework: &signer, user: &signer,
    ) acquires Vault, VaultSigner {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        collateral::init_module_for_test(deployer);
        init_module(deployer);
        collateral::faucet_mint(user);

        let claimed = collateral::faucet_claim_amount();
        deposit(user, claimed);
        assert!(get_balance(signer::address_of(user)) == claimed, 0);

        withdraw(user, claimed);
        assert!(get_balance(signer::address_of(user)) == 0, 1);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, user = @0xCAFE)]
    #[expected_failure(abort_code = 2, location = Self)] // config::E_INSUFFICIENT_FREE_BALANCE
    fun test_withdraw_more_than_free_balance_aborts(
        deployer: &signer, aptos_framework: &signer, user: &signer,
    ) acquires Vault, VaultSigner {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        collateral::init_module_for_test(deployer);
        init_module(deployer);
        withdraw(user, 1);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_lock_and_unlock_margin_is_ledger_only(deployer: &signer) acquires Vault {
        collateral::init_module_for_test(deployer);
        init_module(deployer);
        let trader = @0xCAFE;
        credit_free(borrow_global_mut<Vault>(@zero_day_futures), trader, 1_000_000);
        lock_margin(trader, 400_000);
        assert!(get_balance(trader) == 600_000, 0);
        unlock_margin(trader, 400_000);
        assert!(get_balance(trader) == 1_000_000, 1);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_insurance_fund_draw_is_capped_at_available(deployer: &signer) acquires Vault {
        collateral::init_module_for_test(deployer);
        init_module(deployer);
        credit_insurance_fund(100);
        let drawn = draw_from_insurance_fund(1_000);
        assert!(drawn == 100, 0);
        assert!(get_insurance_fund() == 0, 1);
    }
}
