/**
 * Move abort code -> human-readable message, mirroring docs/spec/abort-codes.md
 * and the numeric constants in contracts/sources/config.move exactly. Keyed
 * on the number, not the symbolic name - the name doesn't survive
 * compilation, only the number reaches the client.
 */
const ABORT_MESSAGES: Record<number, string> = {
  1: "You don't have admin permission for this action.",
  2: "Not enough free balance to cover this.",
  3: "That reduce-only order is larger than your current position.",
  4: "That order would flip your position to the other side - close it first, then open the new side separately.",
  5: "This series has expired; new orders aren't accepted (cancelling is still fine).",
  6: "This series hasn't expired yet, so it can't be settled.",
  7: "That would match against your own order.",
  8: "The index price is missing or too old to trust right now.",
  9: "The posted price is from before this series expired, so it can't be used to settle it yet.",
  10: "This position is healthy and can't be liquidated.",
  11: "Too many traders in one settlement batch.",
  12: "You already have the maximum number of open orders on this series.",
  13: "That order hit its per-transaction fill limit; the rest will match in a later transaction.",
  14: "You've already used the faucet in the last 24 hours.",
  15: "This underlying isn't registered yet.",
  16: "You don't have an open position on this series.",
  17: "That order doesn't exist - it may already be filled or cancelled.",
  18: "You can only cancel your own orders until the series expires.",
  19: "You're not the account authorized to post prices right now.",
};

const MOVE_ABORT_PATTERN = /Move abort in ([^:]+)::(\w+): 0x([0-9a-fA-F]+)/;

export type ParsedMoveAbort = {
  address: string;
  module: string;
  code: number;
  message: string;
};

/**
 * Parses a raw Move VM status string (e.g. from a `FailedTransactionError`'s
 * `transaction.vm_status`, or a simulation error) into a structured abort.
 * Verified against this project's own deployed package, not guessed: calling
 * `vault::withdraw` for more than the free balance surfaces exactly
 * `"Move abort in <address>::vault: 0x2"`.
 */
export function parseMoveAbort(vmStatus: string): ParsedMoveAbort | null {
  const match = MOVE_ABORT_PATTERN.exec(vmStatus);
  if (!match) {
    return null;
  }
  const [, address, module, hexCode] = match;
  const code = Number.parseInt(hexCode, 16);
  return {
    address,
    module,
    code,
    message: ABORT_MESSAGES[code] ?? `Transaction aborted with an unrecognized code (${code}) in ${module}.`,
  };
}

/**
 * Best-effort friendly message for anything a failed transaction might throw
 * - a `FailedTransactionError`-shaped object, a raw vm_status string, or
 * something else entirely (network error, wallet rejection).
 */
export function describeTransactionError(error: unknown): string {
  const vmStatus = extractVmStatus(error);
  if (vmStatus) {
    const parsed = parseMoveAbort(vmStatus);
    if (parsed) {
      return parsed.message;
    }
  }
  if (error instanceof Error) {
    return error.message;
  }
  return "Something went wrong submitting that transaction.";
}

function extractVmStatus(error: unknown): string | null {
  if (typeof error === "string") {
    return error;
  }
  if (error && typeof error === "object") {
    if ("transaction" in error) {
      const transaction = (error as { transaction?: unknown }).transaction;
      if (transaction && typeof transaction === "object" && "vm_status" in transaction) {
        const vmStatus = (transaction as { vm_status?: unknown }).vm_status;
        if (typeof vmStatus === "string") {
          return vmStatus;
        }
      }
    }
    if ("message" in error && typeof (error as { message?: unknown }).message === "string") {
      return (error as { message: string }).message;
    }
  }
  return null;
}
