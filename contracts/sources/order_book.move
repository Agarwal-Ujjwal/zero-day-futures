/// Per-series bid/ask storage: insert, remove, best price, depth aggregation.
/// This is data structure only - no matching logic lives here (that's
/// `matching`), and no validation of orders themselves (that's `orders`).
///
/// Built on `aptos_std::big_ordered_map` (a B+ tree, opportunistically
/// concurrent for non-adjacent keys), per docs/architecture.md's explicit call
/// not to depend on the experimental `aptos_trading` order-book package that
/// ships in the same framework checkout.
///
/// `BigOrderedMap` only iterates in ascending key order, but a book needs
/// "best first" on both sides: lowest price first for asks, highest price
/// first for bids. Asks key on the real price, so ascending = best-first
/// already. Bids key on `U64_MAX - price` instead, so ascending order of that
/// inverted value is descending order of the real price - still best-first.
/// Either way, `order_id` breaks ties within a price, and ids only ever
/// increase, so that tiebreak is price-time priority for free.
module zero_day_futures::order_book {
    use std::option::{Self, Option};
    use std::vector;
    use aptos_std::big_ordered_map::{Self, BigOrderedMap};
    use aptos_std::table::{Self, Table};
    use zero_day_futures::margin;

    // friend zero_day_futures::matching; // added once matching.move exists.
    // friend zero_day_futures::orders; // added once orders.move exists.

    const U64_MAX: u64 = 18446744073709551615;

    struct OrderKey has copy, drop, store {
        price_rank: u64,
        order_id: u64,
    }

    struct RestingOrder has copy, drop, store {
        order_id: u64,
        trader: address,
        price: u64,
        remaining: u64,
        reduce_only: bool,
    }

    /// Where a resting order lives, so `remove`/`reduce_remaining` can find it
    /// in O(log n) instead of scanning a whole side of the book.
    struct OrderLocation has copy, drop, store {
        series_id: u64,
        side: u8,
        key: OrderKey,
    }

    struct Book has store {
        bids: BigOrderedMap<OrderKey, RestingOrder>,
        asks: BigOrderedMap<OrderKey, RestingOrder>,
    }

    struct OrderBookStore has key {
        books: Table<u64, Book>,
        locations: Table<u64, OrderLocation>,
    }

    /// Runs once at publish time.
    fun init_module(deployer: &signer) {
        move_to(deployer, OrderBookStore { books: table::new(), locations: table::new() });
    }

    fun price_rank(side: u8, price: u64): u64 {
        if (side == margin::side_long()) { U64_MAX - price } else { price }
    }

    fun ensure_book(store: &mut OrderBookStore, series_id: u64) {
        if (!table::contains(&store.books, series_id)) {
            table::add(&mut store.books, series_id, Book {
                bids: big_ordered_map::new(),
                asks: big_ordered_map::new(),
            });
        };
    }

    fun side_map_mut(book: &mut Book, side: u8): &mut BigOrderedMap<OrderKey, RestingOrder> {
        if (side == margin::side_long()) { &mut book.bids } else { &mut book.asks }
    }

    fun side_map(book: &Book, side: u8): &BigOrderedMap<OrderKey, RestingOrder> {
        if (side == margin::side_long()) { &book.bids } else { &book.asks }
    }

    /// Inserts a new resting order. `side` is the side it rests on - a buy
    /// order among the bids, a sell order among the asks - after matching has
    /// already consumed whatever it could against the opposite side.
    public(friend) fun insert(
        series_id: u64,
        side: u8,
        order_id: u64,
        trader: address,
        price: u64,
        remaining: u64,
        reduce_only: bool,
    ) acquires OrderBookStore {
        let store = borrow_global_mut<OrderBookStore>(@zero_day_futures);
        ensure_book(store, series_id);
        let book = table::borrow_mut(&mut store.books, series_id);
        let key = OrderKey { price_rank: price_rank(side, price), order_id };
        let order = RestingOrder { order_id, trader, price, remaining, reduce_only };

        big_ordered_map::add(side_map_mut(book, side), key, order);
        table::upsert(&mut store.locations, order_id, OrderLocation { series_id, side, key });
    }

    /// Removes an order entirely - used for a full fill or a cancel.
    public(friend) fun remove(order_id: u64) acquires OrderBookStore {
        let store = borrow_global_mut<OrderBookStore>(@zero_day_futures);
        let location = *table::borrow(&store.locations, order_id);
        let book = table::borrow_mut(&mut store.books, location.series_id);
        big_ordered_map::remove(side_map_mut(book, location.side), &location.key);
        table::remove(&mut store.locations, order_id);
    }

    /// Reduces a resting order's remaining size after a partial fill. Its
    /// price - and so its key - never changes, so this never moves the order.
    public(friend) fun reduce_remaining(order_id: u64, filled: u64) acquires OrderBookStore {
        let store = borrow_global_mut<OrderBookStore>(@zero_day_futures);
        let location = *table::borrow(&store.locations, order_id);
        let book = table::borrow_mut(&mut store.books, location.series_id);
        let order = big_ordered_map::borrow_mut(side_map_mut(book, location.side), &location.key);
        order.remaining = order.remaining - filled;
    }

    public fun order_id_of(order: &RestingOrder): u64 { order.order_id }
    public fun trader_of(order: &RestingOrder): address { order.trader }
    public fun price_of(order: &RestingOrder): u64 { order.price }
    public fun remaining_of(order: &RestingOrder): u64 { order.remaining }
    public fun reduce_only_of(order: &RestingOrder): bool { order.reduce_only }

    #[view]
    public fun exists_order(order_id: u64): bool acquires OrderBookStore {
        table::contains(&borrow_global<OrderBookStore>(@zero_day_futures).locations, order_id)
    }

    /// The best (lowest-price ask / highest-price bid) resting order on
    /// `side` of `series_id`'s book, if any. `matching` walks a side of the
    /// book by repeatedly taking this, filling against it, and calling
    /// `reduce_remaining` or `remove`.
    public fun best(series_id: u64, side: u8): Option<RestingOrder> acquires OrderBookStore {
        let store = borrow_global<OrderBookStore>(@zero_day_futures);
        if (!table::contains(&store.books, series_id)) {
            return option::none()
        };
        let map = side_map(table::borrow(&store.books, series_id), side);
        if (big_ordered_map::is_empty(map)) {
            option::none()
        } else {
            let (_key, order) = big_ordered_map::borrow_front(map);
            option::some(*order)
        }
    }

    #[view]
    /// Aggregated depth for `series_id`, up to `max_levels` distinct prices
    /// per side, best price first: `(bid_prices, bid_sizes, ask_prices,
    /// ask_sizes)`, with parallel entries at the same index forming one level.
    public fun get_depth(
        series_id: u64, max_levels: u64,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) acquires OrderBookStore {
        let store = borrow_global<OrderBookStore>(@zero_day_futures);
        if (!table::contains(&store.books, series_id)) {
            return (vector::empty(), vector::empty(), vector::empty(), vector::empty())
        };
        let book = table::borrow(&store.books, series_id);
        let (bid_prices, bid_sizes) = collect_levels(&book.bids, max_levels);
        let (ask_prices, ask_sizes) = collect_levels(&book.asks, max_levels);
        (bid_prices, bid_sizes, ask_prices, ask_sizes)
    }

    /// Walks `map` from its best (front) entry, merging consecutive orders
    /// that share a price into one level, until `max_levels` distinct prices
    /// have been collected or the map is exhausted.
    fun collect_levels(map: &BigOrderedMap<OrderKey, RestingOrder>, max_levels: u64): (vector<u64>, vector<u64>) {
        let prices = vector::empty<u64>();
        let sizes = vector::empty<u64>();
        let iter = big_ordered_map::internal_new_begin_iter(map);

        while (!big_ordered_map::iter_is_end(&iter, map) && vector::length(&prices) < max_levels) {
            let key = *big_ordered_map::iter_borrow_key(&iter);
            let order = big_ordered_map::borrow(map, &key);
            let last_index = vector::length(&prices);
            if (last_index > 0 && *vector::borrow(&prices, last_index - 1) == order.price) {
                let size_ref = vector::borrow_mut(&mut sizes, last_index - 1);
                *size_ref = *size_ref + order.remaining;
            } else {
                vector::push_back(&mut prices, order.price);
                vector::push_back(&mut sizes, order.remaining);
            };
            iter = big_ordered_map::iter_next(iter, map);
        };
        (prices, sizes)
    }

    #[test_only]
    public fun init_module_for_test(deployer: &signer) {
        init_module(deployer);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_insert_then_best_returns_it(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        insert(1, margin::side_long(), 1, @0xCAFE, 65_000, 10, false);

        let found = best(1, margin::side_long());
        assert!(option::is_some(&found), 0);
        let order = option::extract(&mut found);
        assert!(order_id_of(&order) == 1, 1);
        assert!(price_of(&order) == 65_000, 2);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_best_bid_is_highest_price(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        insert(1, margin::side_long(), 1, @0xCAFE, 64_000, 10, false);
        insert(1, margin::side_long(), 2, @0xCAFE, 66_000, 10, false);
        insert(1, margin::side_long(), 3, @0xCAFE, 65_000, 10, false);

        let found = best(1, margin::side_long());
        let order = option::extract(&mut found);
        assert!(price_of(&order) == 66_000, 0);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_best_ask_is_lowest_price(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        insert(1, margin::side_short(), 1, @0xCAFE, 64_000, 10, false);
        insert(1, margin::side_short(), 2, @0xCAFE, 66_000, 10, false);
        insert(1, margin::side_short(), 3, @0xCAFE, 65_000, 10, false);

        let found = best(1, margin::side_short());
        let order = option::extract(&mut found);
        assert!(price_of(&order) == 64_000, 0);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_same_price_ties_break_by_arrival_order(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        insert(1, margin::side_long(), 5, @0xCAFE, 65_000, 10, false);
        insert(1, margin::side_long(), 2, @0xCAFE, 65_000, 10, false);

        let found = best(1, margin::side_long());
        let order = option::extract(&mut found);
        assert!(order_id_of(&order) == 2, 0); // lower order_id = arrived first
    }

    #[test(deployer = @zero_day_futures)]
    fun test_reduce_remaining_then_remove(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        insert(1, margin::side_long(), 1, @0xCAFE, 65_000, 10, false);
        reduce_remaining(1, 4);

        let found = best(1, margin::side_long());
        let order = option::extract(&mut found);
        assert!(remaining_of(&order) == 6, 0);

        remove(1);
        assert!(!exists_order(1), 1);
        assert!(option::is_none(&best(1, margin::side_long())), 2);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_get_depth_merges_same_price_levels(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        insert(1, margin::side_long(), 1, @0xCAFE, 65_000, 10, false);
        insert(1, margin::side_long(), 2, @0xCAFE, 65_000, 5, false);
        insert(1, margin::side_long(), 3, @0xCAFE, 64_000, 20, false);
        insert(1, margin::side_short(), 4, @0xCAFE, 66_000, 7, false);

        let (bid_prices, bid_sizes, ask_prices, ask_sizes) = get_depth(1, 20);
        assert!(*vector::borrow(&bid_prices, 0) == 65_000, 0);
        assert!(*vector::borrow(&bid_sizes, 0) == 15, 1);
        assert!(*vector::borrow(&bid_prices, 1) == 64_000, 2);
        assert!(*vector::borrow(&bid_sizes, 1) == 20, 3);
        assert!(*vector::borrow(&ask_prices, 0) == 66_000, 4);
        assert!(*vector::borrow(&ask_sizes, 0) == 7, 5);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_get_depth_respects_max_levels(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        insert(1, margin::side_long(), 1, @0xCAFE, 65_000, 10, false);
        insert(1, margin::side_long(), 2, @0xCAFE, 64_000, 10, false);
        insert(1, margin::side_long(), 3, @0xCAFE, 63_000, 10, false);

        let (bid_prices, _bid_sizes, _ask_prices, _ask_sizes) = get_depth(1, 2);
        assert!(vector::length(&bid_prices) == 2, 0);
    }

    #[test(deployer = @zero_day_futures)]
    fun test_get_depth_on_series_with_no_book_is_empty(deployer: &signer) acquires OrderBookStore {
        init_module_for_test(deployer);
        let (bid_prices, bid_sizes, ask_prices, ask_sizes) = get_depth(999, 20);
        assert!(vector::is_empty(&bid_prices), 0);
        assert!(vector::is_empty(&bid_sizes), 1);
        assert!(vector::is_empty(&ask_prices), 2);
        assert!(vector::is_empty(&ask_sizes), 3);
    }
}
