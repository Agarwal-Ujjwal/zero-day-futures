import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { moveFunction } from "@/lib/chain/constants";

/** `collateral::faucet_mint` - mints capped test collateral to the caller. */
export function faucetMint(): InputEntryFunctionData {
  return {
    function: moveFunction("collateral", "faucet_mint"),
    functionArguments: [],
  };
}
