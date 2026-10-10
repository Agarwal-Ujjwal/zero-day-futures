import { aptos } from "@/lib/chain/aptos-client";
import { decodeFeedId, moveFunction } from "@/lib/chain/constants";

export type SeriesInfo = {
  underlying: string;
  feedSymbol: string;
  expiryTs: bigint;
  isSettled: boolean;
  settlementPrice: bigint;
};

/**
 * `series::get_series`. `settlementPrice` is meaningless when `isSettled` is
 * false - callers must check that flag, not treat 0 as "unset" (mirrors the
 * same caveat in the Move view's own doc comment).
 */
export async function getSeries(seriesId: bigint): Promise<SeriesInfo> {
  const [underlying, pythFeedId, expiryTs, isSettled, settlementPrice] = await aptos.view<
    [string, string, string, boolean, string]
  >({
    payload: { function: moveFunction("series", "get_series"), functionArguments: [seriesId] },
  });
  return {
    underlying,
    feedSymbol: decodeFeedId(pythFeedId),
    expiryTs: BigInt(expiryTs),
    isSettled,
    settlementPrice: BigInt(settlementPrice),
  };
}

export async function existsSeries(seriesId: bigint): Promise<boolean> {
  const [exists] = await aptos.view<[boolean]>({
    payload: { function: moveFunction("series", "exists_series"), functionArguments: [seriesId] },
  });
  return exists;
}

export async function isExpired(seriesId: bigint): Promise<boolean> {
  const [expired] = await aptos.view<[boolean]>({
    payload: { function: moveFunction("series", "is_expired"), functionArguments: [seriesId] },
  });
  return expired;
}

/** `series::get_latest_series_id` - aborts on-chain if `underlying` was never registered. */
export async function getLatestSeriesId(underlying: string): Promise<bigint> {
  const [seriesId] = await aptos.view<[string]>({
    payload: { function: moveFunction("series", "get_latest_series_id"), functionArguments: [underlying] },
  });
  return BigInt(seriesId);
}
