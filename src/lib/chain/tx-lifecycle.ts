import type { Account, CommittedTransactionResponse, InputGenerateTransactionPayloadData } from "@aptos-labs/ts-sdk";
import { aptos } from "@/lib/chain/aptos-client";
import { describeTransactionError } from "@/lib/chain/errors";

export type TxResult =
  | { status: "success"; hash: string; transaction: CommittedTransactionResponse }
  | { status: "failed"; hash: string; message: string };

/**
 * Waits for a submitted transaction - from the wallet adapter or a
 * server-signed submission, doesn't matter which - to land, and classifies
 * the result. This is the one place that turns a Move abort into the
 * friendly message from `lib/chain/errors`, so UI and keeper code never
 * re-implement that parsing themselves.
 */
export async function waitForResult(hash: string): Promise<TxResult> {
  try {
    const transaction = await aptos.waitForTransaction({ transactionHash: hash });
    return { status: "success", hash, transaction };
  } catch (error) {
    return { status: "failed", hash, message: describeTransactionError(error) };
  }
}

/**
 * Server-only: builds, signs and submits `payload` with `signerAccount`,
 * then waits for and classifies the result. Used by the keeper, which holds
 * its own `Account` from `KEEPER_PRIVATE_KEY` - browser code never calls
 * this, it always signs through the connected wallet instead (see
 * `src/hooks/use-submit-tx.ts`).
 */
export async function signAndSubmit(
  signerAccount: Account,
  payload: InputGenerateTransactionPayloadData,
): Promise<TxResult> {
  const transaction = await aptos.transaction.build.simple({ sender: signerAccount.accountAddress, data: payload });
  const pending = await aptos.signAndSubmitTransaction({ signer: signerAccount, transaction });
  return waitForResult(pending.hash);
}
