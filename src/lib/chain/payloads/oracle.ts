import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { encodeFeedId, moveFunction } from "@/lib/chain/constants";

/**
 * `oracle::post_price` - keeper-only. Not part of the original scaffold:
 * added when Pyth's Aptos discontinuation forced the keeper-posted price
 * fallback (see docs/architecture.md). Used by the keeper tick, never by
 * browser code.
 */
export function postPrice(feedSymbol: string, price: bigint): InputEntryFunctionData {
  return {
    function: moveFunction("oracle", "post_price"),
    functionArguments: [encodeFeedId(feedSymbol), price],
  };
}

/** `oracle::set_keeper` - admin-only, local CLI only; rotates posting authority. */
export function setKeeper(newKeeper: string): InputEntryFunctionData {
  return {
    function: moveFunction("oracle", "set_keeper"),
    functionArguments: [newKeeper],
  };
}
