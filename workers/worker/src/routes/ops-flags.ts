import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { opsFlag } from "../db/schema";
import { OPS_FLAG_KEYS, clearFlagCache } from "../ops/feature-flags";

/**
 * Admin-only routes to inspect/toggle server-owned ops flags (see
 * ../ops/feature-flags.ts). Mounted at /ops/flags in src/index.ts.
 *
 * GATING (documented follow-up, not fixed here): this worker has no
 * general-purpose admin/internal-auth system (confirmed by repo research —
 * only Better Auth end-user sessions and the test-only ENABLE_TEST_AUTH
 * gate exist). This route uses the SAME shape as ../routes/test-auth.ts
 * (absent-by-default env var + timing-safe secret compare + always-404 on
 * any gate failure) but with its own dedicated secrets:
 *   - c.env.ENABLE_OPS_ADMIN === 'true'
 *   - X-Ops-Admin-Secret header matches c.env.OPS_ADMIN_SECRET (constant-time)
 * Production wrangler.jsonc does NOT define either — set them only on
 * dev/staging via `wrangler secret put ENABLE_OPS_ADMIN` / `OPS_ADMIN_SECRET`.
 * A real admin-auth system (e.g. a role column on `user` + session-based
 * admin check) is a follow-up; this is deliberately the same stopgap shape
 * as test-auth, not a new pattern to maintain.
 */

export const opsFlagsRoutes = new Hono<{ Bindings: Env }>();

function timingSafeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const bufA = encoder.encode(a);
  const bufB = encoder.encode(b);
  let diff = bufA.length ^ bufB.length;
  const len = Math.max(bufA.length, bufB.length);
  for (let i = 0; i < len; i++) {
    diff |= (bufA[i] ?? 0) ^ (bufB[i] ?? 0);
  }
  return diff === 0;
}

function gateOrNotFound(c: {
  env: Env;
  req: { header: (name: string) => string | undefined };
}): Response | null {
  const enabled = c.env.ENABLE_OPS_ADMIN;
  if (!enabled || enabled !== "true") {
    return new Response("Not Found", { status: 404 });
  }
  const expected = c.env.OPS_ADMIN_SECRET;
  if (!expected) {
    return new Response("Not Found", { status: 404 });
  }
  const provided = c.req.header("X-Ops-Admin-Secret");
  if (!provided || !timingSafeEqual(provided, expected)) {
    return new Response("Not Found", { status: 404 });
  }
  return null;
}

// GET /ops/flags — list every known flag key and its current DB value.
// `enabled: null` means the row hasn't been seeded/toggled yet (the
// effective runtime value in that case comes from FLAG_DEFAULTS in
// ../ops/feature-flags.ts, not from this endpoint).
opsFlagsRoutes.get("/", async (c) => {
  const gate = gateOrNotFound(c);
  if (gate) return gate;

  const db = createDb(c.env.DB);
  const rows = await db.select().from(opsFlag).all();
  const byKey = new Map(rows.map((r) => [r.key, r]));

  return c.json({
    flags: OPS_FLAG_KEYS.map((key) => {
      const row = byKey.get(key);
      return {
        key,
        enabled: row?.enabled ?? null,
        updatedAt: row?.updatedAt?.toISOString() ?? null,
      };
    }),
  });
});

// POST /ops/flags/:key  { "enabled": boolean } — upsert a flag's value.
opsFlagsRoutes.post("/:key", async (c) => {
  const gate = gateOrNotFound(c);
  if (gate) return gate;

  const key = c.req.param("key");
  if (!(OPS_FLAG_KEYS as readonly string[]).includes(key)) {
    return c.json({ error: `unknown flag key: ${key}` }, 400);
  }

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "Invalid JSON" }, 400);
  }
  const { enabled } = (body ?? {}) as { enabled?: unknown };
  if (typeof enabled !== "boolean") {
    return c.json({ error: "body must be { enabled: boolean }" }, 400);
  }

  const db = createDb(c.env.DB);
  const now = new Date();
  await db
    .insert(opsFlag)
    .values({ key, enabled, updatedAt: now })
    .onConflictDoUpdate({
      target: opsFlag.key,
      set: { enabled, updatedAt: now },
    });

  // Only clears THIS isolate's cache — see feature-flags.ts's CACHE_TTL_MS
  // doc comment for the up-to-30s cross-isolate propagation tradeoff.
  clearFlagCache(key);

  return c.json({ key, enabled, updatedAt: now.toISOString() });
});
