import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { moveFunction, type Side, type TimeInForce } from "@/lib/chain/constants";

export type PlaceOrderArgs = {
  seriesId: bigint;
  side: Side;
  price: bigint;
  size: bigint;
  tif: TimeInForce;
  reduceOnly: boolean;
};

/**
 * `orders::place_order` - locks initial margin (unless reduce-only), matches
 * against the opposite side of the book, and rests (GTC) or drops (IOC)
 * whatever's left. A "market order" is just an IOC order with a generous
 * `price` as a slippage bound; there's no separate market-order payload.
 */
export function placeOrder(args: PlaceOrderArgs): InputEntryFunctionData {
  return {
    function: moveFunction("orders", "place_order"),
    functionArguments: [args.seriesId, args.side, args.price, args.size, args.tif, args.reduceOnly],
  };
}

/** `orders::cancel_order` - releases whatever margin was locked for the unfilled remainder. */
export function cancelOrder(orderId: bigint): InputEntryFunctionData {
  return {
    function: moveFunction("orders", "cancel_order"),
    functionArguments: [orderId],
  };
}
