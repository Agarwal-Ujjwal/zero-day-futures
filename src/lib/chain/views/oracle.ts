import { aptos } from "@/lib/chain/aptos-client";
import { encodeFeedId, moveFunction } from "@/lib/chain/constants";

export type LatestPrice = {
  price: bigint;
  postedAt: bigint;
};

/**
 * `oracle::get_latest_price` - display-only, no staleness check (that's
 * enforced on-chain inside `liquidate`/`settle_positions`, never here). Reads
 * as `{price: 0n, postedAt: 0n}` for a feed that's never been posted.
 */
export async function getLatestPrice(feedSymbol: string): Promise<LatestPrice> {
  const [price, postedAt] = await aptos.view<[string, string]>({
    payload: {
      function: moveFunction("oracle", "get_latest_price"),
      functionArguments: [encodeFeedId(feedSymbol)],
    },
  });
  return { price: BigInt(price), postedAt: BigInt(postedAt) };
}
