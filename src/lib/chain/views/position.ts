import { aptos } from "@/lib/chain/aptos-client";
import { moveFunction, PositionStatus, type Side } from "@/lib/chain/constants";

export type Position = {
  side: Side;
  size: bigint;
  entryPrice: bigint;
  margin: bigint;
  realizedPnlIsNegative: boolean;
  realizedPnlMagnitude: bigint;
  status: PositionStatus;
};

/**
 * `position::get_position` - the view function returns the `Position`
 * struct serialized as a plain JSON object keyed by its Move field names
 * (verified directly against the deployed package, e.g.
 * `{"side":0,"size":"0","entry_price":"0","margin":"0",
 * "realized_pnl_is_negative":false,"realized_pnl_magnitude":"0","status":1}`
 * for an empty position) - this is not otherwise documented in the SDK's
 * `MoveValue` type, which models primitives and arrays but not structs.
 *
 * Reads as a flat/closed position rather than throwing when the pair has
 * never traded, matching `position::empty_position()`.
 */
export async function getPosition(trader: string, seriesId: bigint): Promise<Position> {
  const [raw] = await aptos.view<[RawPosition]>({
    payload: {
      function: moveFunction("position", "get_position"),
      functionArguments: [trader, seriesId],
    },
  });
  return {
    side: raw.side as Side,
    size: BigInt(raw.size),
    entryPrice: BigInt(raw.entry_price),
    margin: BigInt(raw.margin),
    realizedPnlIsNegative: raw.realized_pnl_is_negative,
    realizedPnlMagnitude: BigInt(raw.realized_pnl_magnitude),
    status: raw.status as PositionStatus,
  };
}

export function isOpen(position: Position): boolean {
  return position.status === PositionStatus.Open;
}

type RawPosition = {
  side: number;
  size: string;
  entry_price: string;
  margin: string;
  realized_pnl_is_negative: boolean;
  realized_pnl_magnitude: string;
  status: number;
};
