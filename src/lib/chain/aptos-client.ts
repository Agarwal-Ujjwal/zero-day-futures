import { Aptos, AptosConfig, Network } from "@aptos-labs/ts-sdk";
import { publicEnv } from "@/lib/env";

const NETWORK_MAP = {
  mainnet: Network.MAINNET,
  testnet: Network.TESTNET,
  devnet: Network.DEVNET,
  local: Network.LOCAL,
} as const;

/**
 * The one Aptos SDK client instance for the app - server routes, the keeper,
 * and client components all share this. `clientConfig.API_KEY` is a
 * domain-restricted key (see .env.example), safe to expose via
 * `NEXT_PUBLIC_APTOS_API_KEY`; it only raises this app's fullnode rate limit,
 * it isn't a secret that grants any capability.
 */
export const aptos = new Aptos(
  new AptosConfig({
    network: NETWORK_MAP[publicEnv.NEXT_PUBLIC_APTOS_NETWORK],
    clientConfig: publicEnv.NEXT_PUBLIC_APTOS_API_KEY ? { API_KEY: publicEnv.NEXT_PUBLIC_APTOS_API_KEY } : undefined,
  }),
);
