/// The mock USDC collateral asset and its capped faucet. This is the only module
/// that creates value out of nothing (the faucet, testnet-only); every other
/// module only moves value that this module minted. Built on the Fungible Asset
/// standard so `vault` can hold and move it like any other FA.
module zero_day_futures::collateral {
    use std::option;
    use std::signer;
    use std::string;
    use aptos_std::table::{Self, Table};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use zero_day_futures::config;

    /// Fixed seed for the named object holding the mUSDC metadata, so its address
    /// can always be re-derived from `@zero_day_futures` instead of being stored.
    const COLLATERAL_SEED: vector<u8> = b"zero_day_futures::mock_usdc";

    /// 10,000.00 mUSDC per faucet claim, at 6 decimals.
    const FAUCET_AMOUNT: u64 = 10_000_000_000;
    const FAUCET_COOLDOWN_SECONDS: u64 = 86_400;

    /// Mint/transfer/burn authority over mUSDC, stored under the metadata object's
    /// own address. No user account, and no other module, ever holds these refs.
    struct ManagingRefs has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
    }

    /// Per-address faucet cooldown tracker, stored once under the publisher so the
    /// cooldown check never needs to scan every address that has ever claimed.
    struct FaucetHistory has key {
        last_claim_at: Table<address, u64>,
    }

    /// Runs once at publish time: creates the mUSDC metadata object with primary
    /// store support, stores its mint/transfer/burn refs, and sets up the faucet
    /// history table.
    fun init_module(deployer: &signer) {
        let constructor_ref = object::create_named_object(deployer, COLLATERAL_SEED);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            string::utf8(b"Mock USDC"),
            string::utf8(b"mUSDC"),
            config::collateral_decimals(),
            string::utf8(b""),
            string::utf8(b""),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let metadata_signer = &object::generate_signer(&constructor_ref);
        move_to(metadata_signer, ManagingRefs { mint_ref, transfer_ref, burn_ref });

        move_to(deployer, FaucetHistory { last_claim_at: table::new() });
    }

    /// The mUSDC fungible asset's metadata object. `vault` and anything else that
    /// needs to name this asset calls this instead of hardcoding its address.
    public fun metadata(): Object<Metadata> {
        let package_address = @zero_day_futures;
        object::address_to_object(object::create_object_address(&package_address, COLLATERAL_SEED))
    }

    /// Mint `FAUCET_AMOUNT` of test collateral into the caller's primary store, at
    /// most once per `FAUCET_COOLDOWN_SECONDS` per address.
    public entry fun faucet_mint(account: &signer) acquires ManagingRefs, FaucetHistory {
        let claimant = signer::address_of(account);
        let now = timestamp::now_seconds();
        let history = borrow_global_mut<FaucetHistory>(@zero_day_futures);

        if (table::contains(&history.last_claim_at, claimant)) {
            let last_claim = *table::borrow(&history.last_claim_at, claimant);
            assert!(now >= last_claim + FAUCET_COOLDOWN_SECONDS, config::e_faucet_cooldown());
        };
        table::upsert(&mut history.last_claim_at, claimant, now);

        let refs = borrow_global<ManagingRefs>(object::object_address(&metadata()));
        primary_fungible_store::mint(&refs.mint_ref, claimant, FAUCET_AMOUNT);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, user = @0xCAFE)]
    fun test_faucet_mint_credits_caller(
        deployer: &signer, aptos_framework: &signer, user: &signer,
    ) acquires ManagingRefs, FaucetHistory {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(deployer);
        faucet_mint(user);
        assert!(
            primary_fungible_store::balance(signer::address_of(user), metadata()) == FAUCET_AMOUNT,
            0,
        );
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, user = @0xCAFE)]
    #[expected_failure(abort_code = 14, location = Self)] // config::E_FAUCET_COOLDOWN
    fun test_faucet_mint_rejects_second_claim_within_cooldown(
        deployer: &signer, aptos_framework: &signer, user: &signer,
    ) acquires ManagingRefs, FaucetHistory {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(deployer);
        faucet_mint(user);
        faucet_mint(user);
    }

    #[test(deployer = @zero_day_futures, aptos_framework = @aptos_framework, user = @0xCAFE)]
    fun test_faucet_mint_allowed_again_after_cooldown(
        deployer: &signer, aptos_framework: &signer, user: &signer,
    ) acquires ManagingRefs, FaucetHistory {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(deployer);
        faucet_mint(user);
        timestamp::fast_forward_seconds(FAUCET_COOLDOWN_SECONDS);
        faucet_mint(user);
        assert!(
            primary_fungible_store::balance(signer::address_of(user), metadata()) == 2 * FAUCET_AMOUNT,
            0,
        );
    }
}
