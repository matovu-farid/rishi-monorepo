import { eq } from "drizzle-orm";
import { createDb } from "../db/drizzle";
import { opsFlag } from "../db/schema";

/**
 * The five server-owned flags from the pricing/trial-launch design doc's
 * "Telemetry, abuse, and rollout controls" section: "Add server-owned flags
 * for shadow accounting, public trial availability, paid-limit enforcement,
 * Voice Chat availability, and an emergency AI kill switch."
 */
export const OPS_FLAG_KEYS = [
  "shadow_accounting",
  "public_trial_available",
  "paid_limit_enforcement",
  "voice_chat_available",
  "ai_kill_switch",
] as const;

export type OpsFlagKey = (typeof OPS_FLAG_KEYS)[number];

/**
 * What `isFlagEnabled` returns when the flag's row is missing from D1 (not
 * yet seeded, or a brand-new key added to this array before the seed script
 * has been re-run in some environment) OR when the D1 read itself throws.
 * Each default is chosen for what happens if the system guesses wrong —
 * this is NOT a uniform "default false" because the flags gate very
 * different failure directions:
 *
 *   - shadow_accounting: default TRUE. This is internal telemetry-only
 *     accounting (no user-facing effect) that the design doc wants running
 *     *before* public launch to validate the new pricing model. Defaulting
 *     it on is the safe direction — worst case we collect telemetry nobody
 *     asked for; there is no cost/abuse downside.
 *   - public_trial_available: default FALSE. The design doc is explicit
 *     that "a free trial must not become publicly available until the
 *     Worker can both reject a new provider request and terminate an
 *     in-progress Voice Chat without client cooperation" — an unseeded or
 *     errored read must never accidentally expose the trial. Fail closed.
 *   - paid_limit_enforcement: default TRUE. This flag gates whether paid
 *     and trial allowance limits are actually ENFORCED. Defaulting to "not
 *     enforced" on a missing row or a D1 hiccup would mean unmetered,
 *     unlimited provider usage — a direct, uncapped cost and abuse risk.
 *     Enforcement is the fail-closed-safe direction here, not the
 *     "everything off" direction.
 *   - voice_chat_available: default FALSE. Voice Chat is the most
 *     expensive feature per unit of usage (Realtime tokens). Default off
 *     until an operator has deliberately turned it on. Fail closed.
 *   - ai_kill_switch: default FALSE. This is an emergency STOP control:
 *     `true` means "kill AI features now". Defaulting a missing/errored
 *     read to `true` would turn a transient D1 hiccup into a total,
 *     self-inflicted AI outage — a worse failure mode than staying up
 *     under normal enforcement (which, per the row above, is itself
 *     fail-closed-safe already). The kill switch is operator-invoked, not
 *     a thing whose ABSENCE should imply an emergency.
 *
 * Any key not in this map (typo, or a new flag added to calling code before
 * it's added to OPS_FLAG_KEYS/this map) defaults to `false`: fail closed
 * for anything unrecognized.
 */
const FLAG_DEFAULTS: Record<OpsFlagKey, boolean> = {
  shadow_accounting: true,
  public_trial_available: false,
  paid_limit_enforcement: true,
  voice_chat_available: false,
  ai_kill_switch: false,
};

function defaultFor(key: string): boolean {
  return (OPS_FLAG_KEYS as readonly string[]).includes(key)
    ? FLAG_DEFAULTS[key as OpsFlagKey]
    : false;
}

/**
 * In-memory, per-Worker-isolate cache. TTL is intentionally short (30s) so
 * an operator's flag flip is visible within 30s without a D1 read on every
 * single request. This is a per-isolate cache, not a shared one — a brand
 * new isolate (e.g. one Cloudflare just spun up in another PoP) always
 * reads through to D1 on its first check of a given key, and a flip made
 * via the /ops/flags route (Task 4) only clears the CURRENT isolate's
 * cache. Worst case, some in-flight isolates keep serving a stale value for
 * up to 30s after a flip. This is an accepted tradeoff for flags that
 * operators toggle rarely and deliberately (not a per-request signal) — if
 * `ai_kill_switch` specifically ever needs sub-second global propagation,
 * that's a follow-up (e.g. move it to KV, which still has propagation
 * delay, or to a Durable Object broadcast), not something to solve here.
 */
const CACHE_TTL_MS = 30_000;

type CacheEntry = { value: boolean; expiresAt: number };
const cache = new Map<string, CacheEntry>();

/**
 * Returns whether a server-owned ops flag is enabled. Fails closed: a
 * missing row or a D1 read error returns the per-flag default above, never
 * throws — callers should be able to call this on every request without a
 * try/catch.
 */
export async function isFlagEnabled(env: Env, key: string): Promise<boolean> {
  const now = Date.now();
  const cached = cache.get(key);
  if (cached && cached.expiresAt > now) {
    return cached.value;
  }

  const fallback = defaultFor(key);
  let value = fallback;
  try {
    const db = createDb(env.DB);
    const row = await db
      .select({ enabled: opsFlag.enabled })
      .from(opsFlag)
      .where(eq(opsFlag.key, key))
      .get();
    if (row) {
      value = row.enabled;
    }
  } catch (err) {
    console.error(`isFlagEnabled: D1 read failed for "${key}", using default`, err);
    value = fallback;
  }

  cache.set(key, { value, expiresAt: now + CACHE_TTL_MS });
  return value;
}

/**
 * Clears this isolate's cached value for one flag (or all flags, if no key
 * is given). Called by the /ops/flags toggle route right after a write so
 * the SAME isolate that just handled the toggle reflects it immediately;
 * other isolates catch up within CACHE_TTL_MS. Also useful from tests.
 */
export function clearFlagCache(key?: string): void {
  if (key) {
    cache.delete(key);
  } else {
    cache.clear();
  }
}
