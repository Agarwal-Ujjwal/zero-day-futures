import { z } from "zod";

const publicEnvSchema = z.object({
  NEXT_PUBLIC_APTOS_NETWORK: z.enum(["mainnet", "testnet", "devnet", "local"]).default("testnet"),
  NEXT_PUBLIC_MODULE_ADDRESS: z
    .string()
    .regex(/^0x[0-9a-fA-F]+$/, "NEXT_PUBLIC_MODULE_ADDRESS must be a 0x-prefixed hex address"),
  NEXT_PUBLIC_APTOS_API_KEY: z.string().optional(),
});

/**
 * Server-only secrets are all optional here because most of them belong to
 * pieces of the stack that don't exist yet (lib/db, lib/sync, lib/keeper).
 * Each gets tightened to `.min(1)` in the same commit that starts actually
 * reading it, so a half-built env never silently breaks an unrelated route.
 */
const serverEnvSchema = z.object({
  APTOS_INDEXER_URL: z.string().url().optional(),
  APTOS_INDEXER_API_KEY: z.string().optional(),
  PRICE_SOURCE_API_KEY: z.string().optional(),
  KEEPER_PRIVATE_KEY: z.string().optional(),
  CRON_SECRET: z.string().optional(),
  DATABASE_URL: z.string().optional(),
});

function parsePublicEnv() {
  const parsed = publicEnvSchema.safeParse({
    NEXT_PUBLIC_APTOS_NETWORK: process.env.NEXT_PUBLIC_APTOS_NETWORK,
    NEXT_PUBLIC_MODULE_ADDRESS: process.env.NEXT_PUBLIC_MODULE_ADDRESS,
    NEXT_PUBLIC_APTOS_API_KEY: process.env.NEXT_PUBLIC_APTOS_API_KEY,
  });
  if (!parsed.success) {
    throw new Error(`Invalid public environment variables:\n${parsed.error.message}`);
  }
  return parsed.data;
}

function parseServerEnv() {
  const parsed = serverEnvSchema.safeParse({
    APTOS_INDEXER_URL: process.env.APTOS_INDEXER_URL,
    APTOS_INDEXER_API_KEY: process.env.APTOS_INDEXER_API_KEY,
    PRICE_SOURCE_API_KEY: process.env.PRICE_SOURCE_API_KEY,
    KEEPER_PRIVATE_KEY: process.env.KEEPER_PRIVATE_KEY,
    CRON_SECRET: process.env.CRON_SECRET,
    DATABASE_URL: process.env.DATABASE_URL,
  });
  if (!parsed.success) {
    throw new Error(`Invalid server environment variables:\n${parsed.error.message}`);
  }
  return parsed.data;
}

/** Safe to import from client components - only `NEXT_PUBLIC_*` values. */
export const publicEnv = parsePublicEnv();

/**
 * Server secrets. Call this, don't destructure it at module scope - it
 * throws if called from the browser, so a route that accidentally imports
 * client-side code pulling this in fails loudly instead of leaking undefined
 * secrets silently.
 */
export function getServerEnv() {
  if (typeof window !== "undefined") {
    throw new Error("getServerEnv() was called from the browser - server secrets never ship to the client.");
  }
  return parseServerEnv();
}
