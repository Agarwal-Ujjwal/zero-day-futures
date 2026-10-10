import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { moveFunction } from "@/lib/chain/constants";

/** `clearing::add_margin` - the on-chain side of the margin-call "Add margin" button. */
export function addMargin(seriesId: bigint, amount: bigint): InputEntryFunctionData {
  return {
    function: moveFunction("clearing", "add_margin"),
    functionArguments: [seriesId, amount],
  };
}
