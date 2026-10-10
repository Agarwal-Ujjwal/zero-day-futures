import type { InputEntryFunctionData } from "@aptos-labs/ts-sdk";
import { moveFunction } from "@/lib/chain/constants";

/** `vault::deposit` - moves `amount` of mUSDC from the caller's wallet into vault custody. */
export function deposit(amount: bigint): InputEntryFunctionData {
  return {
    function: moveFunction("vault", "deposit"),
    functionArguments: [amount],
  };
}

/** `vault::withdraw` - moves `amount` of mUSDC from the caller's free balance back to their wallet. */
export function withdraw(amount: bigint): InputEntryFunctionData {
  return {
    function: moveFunction("vault", "withdraw"),
    functionArguments: [amount],
  };
}
