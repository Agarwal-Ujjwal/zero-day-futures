import { aptos } from "@/lib/chain/aptos-client";
import { moveFunction } from "@/lib/chain/constants";

export type DepthLevel = {
  price: bigint;
  size: bigint;
};

export type Depth = {
  bids: DepthLevel[];
  asks: DepthLevel[];
};

/**
 * `order_book::get_depth` - aggregated order-book levels, best price first on
 * each side, up to `levels` distinct prices per side. Verified against the
 * deployed package: an empty book returns `[[],[],[],[]]`.
 */
export async function getDepth(seriesId: bigint, levels: number): Promise<Depth> {
  const [bidPrices, bidSizes, askPrices, askSizes] = await aptos.view<[string[], string[], string[], string[]]>({
    payload: {
      function: moveFunction("order_book", "get_depth"),
      functionArguments: [seriesId, levels],
    },
  });
  return {
    bids: zipLevels(bidPrices, bidSizes),
    asks: zipLevels(askPrices, askSizes),
  };
}

function zipLevels(prices: string[], sizes: string[]): DepthLevel[] {
  return prices.map((price, i) => ({ price: BigInt(price), size: BigInt(sizes[i]) }));
}
