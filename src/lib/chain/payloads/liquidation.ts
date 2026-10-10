import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { moveFunction } from "@/lib/chain/constants";

/**
 * `liquidation::liquidate` - permissionless; re-verifies the margin
 * condition on-chain against the oracle price before closing anything.
 */
export function liquidate(seriesId: bigint, trader: string): InputEntryFunctionData {
  return {
    function: moveFunction("liquidation", "liquidate"),
    functionArguments: [seriesId, trader],
  };
}
