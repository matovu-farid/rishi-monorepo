/**
 * Better Auth session resolver for Apple IAP endpoints.
 *
 * Mirrors the dev-bypass + getSession behavior of `requireAuth` in
 * src/index.ts but exposed as a pure DI'd function so endpoint handlers
 * can be tested without a Hono context. Apple endpoints (14-04 verify-
 * receipt, 14-06 /me) still mount `requireAuth` as middleware in
 * src/index.ts — this helper is what the handler calls internally OR
 * what the handler's tests substitute for.
 *
 * Design (14-RESEARCH §3.4, §10.1):
 * - All deps DI'd; no env reads, no module-level state.
 * - `auth` is `ReturnType<typeof createAuth>` in production, a vi.fn()
 *   stub in tests.
 * - Returns a discriminated union — never throws on missing/invalid
 *   session. Caller maps `unauthorized` → HTTP 401.
 *
 * NOTE: This file MUST NOT import from `../index` — `index.ts` will
 * eventually import this helper, and a back-edge would form a cycle.
 * `constantTimeEq` is duplicated locally for that reason.
 */

/**
 * Result of resolving a Better Auth session for an Apple IAP request.
 * Discriminated union so callers can `if ("unauthorized" in result)`
 * cleanly without a thrown exception.
 */
export type AppleAuthResult =
  | { userId: string }
  | { unauthorized: true };

/** DI'd input to {@link resolveAppleAuth}. */
export interface AppleAuthInput {
  /**
   * Better Auth instance, in production `createAuth(env)` from `../auth`.
   * Typed structurally to keep this module decoupled from the full
   * Better Auth type surface (which is large and not needed here).
   */
  auth: {
    api: {
      getSession: (input: { headers: Headers }) => Promise<{ user: { id: string } } | null>;
    };
  };
  /** Request headers (production: `c.req.raw.headers`). */
  headers: Headers;
  /** `env.DEV_BYPASS_SECRET` — `undefined` disables the bypass branch. */
  devBypassSecret: string | undefined;
  /** Value of the `X-Dev-Bypass` request header, or `undefined`. */
  devBypassHeader: string | undefined;
}

/**
 * Constant-time string compare. Duplicated from `src/index.ts` (which
 * uses `crypto.subtle.timingSafeEqual` — a Workers-only API) to avoid
 * a circular import once Apple endpoints in `index.ts` start calling
 * this helper, AND to keep this helper runnable under the worker's
 * vitest config (`environment: "node"`) where `crypto.subtle.timingSafeEqual`
 * is not exposed. The XOR-loop here is the textbook constant-time
 * compare and runs in both runtimes. Length mismatch returns early —
 * the secret length is fixed by deployment so that branch is not a
 * meaningful side channel.
 */
function constantTimeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Resolve the Better Auth user id for an Apple IAP request.
 *
 * Behavior (matches `requireAuth` in src/index.ts):
 * 1. If `devBypassSecret` is set AND `devBypassHeader` matches it
 *    (constant-time), short-circuit to `{ userId: "dev-user" }` without
 *    calling Better Auth. Lets local dev hit Apple endpoints without a
 *    real signed-in session.
 * 2. Otherwise, call `auth.api.getSession({ headers })`. Missing/invalid
 *    session → `{ unauthorized: true }`. Valid session → `{ userId }`.
 *
 * Never throws on a null session — callers map `unauthorized` to HTTP 401
 * themselves. Re-throws any underlying Better Auth error so transport
 * failures surface as 5xx upstream.
 */
export async function resolveAppleAuth(input: AppleAuthInput): Promise<AppleAuthResult> {
  if (input.devBypassSecret && input.devBypassHeader) {
    if (constantTimeEq(input.devBypassHeader, input.devBypassSecret)) {
      return { userId: "dev-user" };
    }
  }
  const session = await input.auth.api.getSession({ headers: input.headers });
  if (!session) return { unauthorized: true };
  return { userId: session.user.id };
}
