import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { encodeFeedId, moveFunction } from "@/lib/chain/constants";

/** `series::add_underlying` - admin-only, local CLI only. */
export function addUnderlying(underlying: string, feedSymbol: string): InputEntryFunctionData {
  return {
    function: moveFunction("series", "add_underlying"),
    functionArguments: [underlying, encodeFeedId(feedSymbol)],
  };
}

/** `series::create_series` - admin-only; the standard 24h cycle or a short-expiry demo series. */
export function createSeries(underlying: string, feedSymbol: string, expiryTs: bigint): InputEntryFunctionData {
  return {
    function: moveFunction("series", "create_series"),
    functionArguments: [underlying, encodeFeedId(feedSymbol), expiryTs],
  };
}

/** `series::roll_series` - permissionless; creates the next standard-duration series. */
export function rollSeries(underlying: string): InputEntryFunctionData {
  return {
    function: moveFunction("series", "roll_series"),
    functionArguments: [underlying],
  };
}
