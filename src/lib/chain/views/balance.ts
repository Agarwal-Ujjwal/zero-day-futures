import { aptos } from "@/lib/chain/aptos-client";
import { moveFunction } from "@/lib/chain/constants";

/** `vault::get_balance` - free (withdrawable / order-eligible) balance. Reads as 0n if never deposited. */
export async function getBalance(trader: string): Promise<bigint> {
  const [balance] = await aptos.view<[string]>({
    payload: { function: moveFunction("vault", "get_balance"), functionArguments: [trader] },
  });
  return BigInt(balance);
}

/** `vault::get_insurance_fund` - the backstop balance, drawn down by liquidation penalties. */
export async function getInsuranceFund(): Promise<bigint> {
  const [balance] = await aptos.view<[string]>({
    payload: { function: moveFunction("vault", "get_insurance_fund"), functionArguments: [] },
  });
  return BigInt(balance);
}
