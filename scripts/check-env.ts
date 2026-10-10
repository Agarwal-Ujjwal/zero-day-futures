/**
 * Local-only sanity check: confirms `.env.local` is valid and that
 * `lib/chain` can actually talk to the configured Aptos network - not just
 * type-check, but reach the real deployed package and get real answers back.
 *
 * Run with: pnpm exec tsx scripts/check-env.ts
 */
import { config } from "dotenv";

config({ path: ".env.local" });

async function main() {
  const { publicEnv } = await import("@/lib/env");
  console.log(`Network: ${publicEnv.NEXT_PUBLIC_APTOS_NETWORK}`);
  console.log(`Module address: ${publicEnv.NEXT_PUBLIC_MODULE_ADDRESS}`);

  const { aptos } = await import("@/lib/chain/aptos-client");
  const modules = await aptos.getAccountModules({ accountAddress: publicEnv.NEXT_PUBLIC_MODULE_ADDRESS });
  console.log(`Modules published at that address: ${modules.length}`);
  if (modules.length === 0) {
    throw new Error("No modules found - is NEXT_PUBLIC_MODULE_ADDRESS correct, and is the package published?");
  }

  const { getSeries, existsSeries } = await import("@/lib/chain/views/series");
  const { getDepth } = await import("@/lib/chain/views/depth");
  const { getLatestPrice } = await import("@/lib/chain/views/oracle");
  const { getBalance } = await import("@/lib/chain/views/balance");

  if (await existsSeries(1n)) {
    const series = await getSeries(1n);
    console.log(`Series 1: ${series.underlying} (${series.feedSymbol}), expires ${series.expiryTs}`);
    const price = await getLatestPrice(series.feedSymbol);
    console.log(`Latest ${series.feedSymbol} price: ${price.price} (posted_at ${price.postedAt})`);
    const depth = await getDepth(1n, 5);
    console.log(`Depth: ${depth.bids.length} bid levels, ${depth.asks.length} ask levels`);
  } else {
    console.log("Series 1 does not exist yet - run the seed steps first.");
  }

  const balance = await getBalance(publicEnv.NEXT_PUBLIC_MODULE_ADDRESS);
  console.log(`Deployer's own vault free balance: ${balance}`);

  console.log("\nAll checks passed.");
}

main().catch((error) => {
  console.error("check-env failed:", error);
  process.exitCode = 1;
});
