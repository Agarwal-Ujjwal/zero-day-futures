import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { moveFunction, SETTLEMENT_BATCH_MAX } from "@/lib/chain/constants";

/**
 * `settlement::settle_positions` - permissionless; fixes the settlement
 * price on the first call for a series, reuses it on every later one.
 * `traders` must not exceed `SETTLEMENT_BATCH_MAX` - the keeper batches and
 * repeats instead of sending one oversized call.
 */
export function settlePositions(seriesId: bigint, traders: string[]): InputEntryFunctionData {
  if (traders.length > SETTLEMENT_BATCH_MAX) {
    throw new Error(`settlePositions: ${traders.length} traders exceeds the batch max of ${SETTLEMENT_BATCH_MAX}`);
  }
  return {
    function: moveFunction("settlement", "settle_positions"),
    functionArguments: [seriesId, traders],
  };
}
