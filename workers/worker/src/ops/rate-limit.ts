/**
 * Sliding-window rate limiter backed by the dedicated RATE_LIMIT_KV
 * namespace (see wrangler.jsonc, Task 5). This is an ABUSE-DETERRENCE
 * layer, not the authoritative entitlement enforcement — per the no-card-
 * credit-trial design doc: "Rate limits and account-abuse controls remain
 * in front of trial endpoints. Provider rate limits do not replace
 * account-level entitlement enforcement." The UserUsageLedger /
 * UserTrialLedger Durable Objects (other plans in this batch) remain the
 * source of truth for how much allowance a user has left; this module only
 * throttles the RATE at which requests can attempt to consume that
 * allowance or hit other abuse-prone endpoints.
 *
 * ## Algorithm: sliding window counter
 * Time is divided into fixed `windowSeconds`-sized buckets. Each
 * checkRateLimit call reads the CURRENT and PREVIOUS bucket's counts and
 * computes a weighted estimate:
 *
 *   estimate = currentBucketCount
 *            + previousBucketCount * (1 - elapsedFractionOfCurrentBucket)
 *
 * This avoids the classic fixed-window-counter bug where a burst
 * straddling the boundary between two windows can spike to ~2x the
 * intended limit, while staying cheap: two KV reads + (on an allowed
 * request) one KV write, no per-request log to store or prune.
 *
 * ## Known, accepted tradeoffs (fine for an abuse-deterrence layer)
 *  - KV has no native atomic increment. Two concurrent requests can both
 *    read count=N and both write N+1, undercounting by 1 in rare races.
 *    The ledger DOs remain the hard limiter; this only needs to be "close
 *    enough" to deter scripted abuse, not exactly precise.
 *  - KV is eventually consistent across Cloudflare's edge (global writes
 *    typically propagate within seconds, worst case up to ~60s). A
 *    distributed attacker hitting many PoPs at once could transiently
 *    exceed the nominal limit. Same acceptance as above.
 *  - `expirationTtl` (KV's native per-key TTL) handles counter cleanup —
 *    no cron/sweep job needed.
 */

const BUCKET_KEY_PREFIX = "rl";

function currentBucketStart(nowMs: number, windowSeconds: number): number {
  return Math.floor(nowMs / 1000 / windowSeconds) * windowSeconds;
}

/**
 * Builds the composite key identifying WHO is being checked for one abuse
 * vector. `bucket` should be one of RATE_LIMITS' keys below (or a new
 * caller-defined string for an abuse vector this plan didn't anticipate).
 * `subjectType` distinguishes an account-scoped check from an IP-scoped or
 * session-scoped one — per the design doc's "by account and IP" abuse
 * control requirement, callers should generally run TWO checks (account +
 * ip) per request and require both to pass; see "Follow-up wiring" in the
 * plan doc for exact call sites.
 */
export function rateLimitSubjectKey(
  bucket: string,
  subjectType: "account" | "ip" | "session",
  subjectId: string,
): string {
  return `${bucket}:${subjectType}:${subjectId}`;
}

export async function checkRateLimit(
  env: Env,
  key: string,
  opts: { windowSeconds: number; max: number },
): Promise<{ allowed: boolean; remaining: number }> {
  const { windowSeconds, max } = opts;
  const nowMs = Date.now();
  const currentBucket = currentBucketStart(nowMs, windowSeconds);
  const previousBucket = currentBucket - windowSeconds;
  const currentKvKey = `${BUCKET_KEY_PREFIX}:${key}:${currentBucket}`;
  const previousKvKey = `${BUCKET_KEY_PREFIX}:${key}:${previousBucket}`;

  const [currentRaw, previousRaw] = await Promise.all([
    env.RATE_LIMIT_KV.get(currentKvKey),
    env.RATE_LIMIT_KV.get(previousKvKey),
  ]);
  const currentCount = currentRaw ? Number.parseInt(currentRaw, 10) || 0 : 0;
  const previousCount = previousRaw
    ? Number.parseInt(previousRaw, 10) || 0
    : 0;

  const elapsedSeconds = nowMs / 1000 - currentBucket;
  const weight = Math.max(0, 1 - elapsedSeconds / windowSeconds);
  const estimate = currentCount + previousCount * weight;

  if (estimate >= max) {
    return { allowed: false, remaining: 0 };
  }

  // Only increment on an ALLOWED check — a rejected request shouldn't push
  // the caller further over the limit or refresh their counter's TTL.
  const newCount = currentCount + 1;
  await env.RATE_LIMIT_KV.put(currentKvKey, String(newCount), {
    // Survive past the current bucket so the NEXT bucket's weighted read
    // can still see this count; the +60s buffer absorbs clock/propagation
    // skew between edge locations.
    expirationTtl: windowSeconds * 2 + 60,
  });

  const remaining = Math.max(0, Math.floor(max - estimate - 1));
  return { allowed: true, remaining };
}

/**
 * Concrete limits for the four abuse vectors named in the pricing/trial
 * design doc: "Rate-limit trial grants, narration cache misses, Voice Chat
 * starts, and repeated call-ID registration by account and IP." Each
 * vector has an account-scoped AND an ip-scoped config — BOTH checks must
 * pass (call checkRateLimit twice; see "Follow-up wiring" in the plan doc
 * for exact call sites). Numbers are deliberately conservative-but-
 * generous: they should never throttle one real user's normal
 * reading/listening session, only scripted/automated abuse. Revisit these
 * once production telemetry (recordProviderUsageEvent data, see
 * telemetry.ts) shows real usage distributions.
 */
export const RATE_LIMITS = {
  // ── Trial grant: the one-time 300-credit grant on first login ──────────
  // A legitimate user grants exactly once, ever, ever. 3/account/24h gives
  // headroom for a retried/racy first request (e.g. an app relaunch mid-
  // signup double-firing the grant call) without opening a repeat-grant
  // loophole. 10/IP/24h caps how many NEW accounts one IP can onboard per
  // day — generous for a household/office network, tight enough to blunt
  // scripted mass-account creation for credit farming.
  trialGrantAccount: { windowSeconds: 86_400, max: 3 },
  trialGrantIp: { windowSeconds: 86_400, max: 10 },

  // ── Narration cache miss: a TTS request that misses the R2 cache and so
  // costs real OpenAI money regardless of the caller's plan ──────────────
  // At the design doc's <=1,000-char chunk size with one-chunk prefetch, a
  // real reading/listening session generates roughly one new chunk every
  // 1-2 minutes of playback. 30/10min per account is ~15-30x realistic
  // steady-state usage — enough headroom to fast-forward/skim a whole
  // chapter in one burst, tight enough to blunt a scripted cache-miss-
  // hammering script (which doesn't need to exhaust the user's OWN ledger
  // allowance to cost real provider money at a high rate — e.g. it could
  // send many slightly-different strings that all miss cache while staying
  // within one plan's allowance-per-request cost). 90/10min per IP covers
  // several real accounts sharing one NAT IP.
  narrationCacheMissAccount: { windowSeconds: 600, max: 30 },
  narrationCacheMissIp: { windowSeconds: 600, max: 90 },

  // ── Voice Chat session starts: POST /api/voice-sessions ─────────────────
  // Only one active session per account at a time (ledger-enforced), and a
  // session is capped at 60-75 real minutes. 20/account/hour allows
  // several legitimate retries (e.g. the design doc's registration
  // grace-period failure case: "app must close if registration fails...
  // offers retry") without allowing a start-storm against the ledger DO.
  // 60/IP/hour covers a shared network.
  voiceChatStartAccount: { windowSeconds: 3_600, max: 20 },
  voiceChatStartIp: { windowSeconds: 3_600, max: 60 },

  // ── OpenAI call-ID registration attempts ────────────────────────────────
  // The ledger accepts a call ID exactly once per session (design doc:
  // "accepted once... never exposed to another user"), so this is
  // fundamentally a replay/retry guard, not a real usage limit.
  // `callIdRegistrationSession` is keyed by the Rishi session ID itself
  // (not account/IP — see rateLimitSubjectKey's "session" subjectType),
  // windowed to the longest possible session lifetime (60min = 3600s) with
  // a small max: 5 attempts is far more than the 1 a healthy client needs,
  // but stops a buggy/malicious retry loop from hammering the ledger DO for
  // an entire session's duration. The account/IP variants below add
  // defense-in-depth against a client that opens MANY sessions purely to
  // spam registration attempts across all of them.
  callIdRegistrationSession: { windowSeconds: 3_600, max: 5 },
  callIdRegistrationAccount: { windowSeconds: 3_600, max: 20 },
  callIdRegistrationIp: { windowSeconds: 3_600, max: 60 },
} as const satisfies Record<string, { windowSeconds: number; max: number }>;
