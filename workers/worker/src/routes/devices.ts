import { Hono } from "hono";
import { z } from "zod";
import { devices } from "../db/schema";
import { createDb } from "../db/drizzle";

import { requireAuth } from "../index";
import { requireAiDataConsent } from "../middleware/ai-data-consent";

// 1970->2001 epoch gap. Matches workers/worker/src/routes/changes.ts.
// Required so iOS WorkerClient.swift:96 bare JSONDecoder (.deferredToDate)
// decodes Date.
const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;

/**
 * POST /api/devices/register — Quick-VPX Task 2 (GAP 2).
 *
 * Persists the (userId, deviceToken) pair iOS hands us every time APNs
 * mints a fresh device token. The unique index on (user_id, device_token)
 * lets us idempotently UPSERT via onConflictDoUpdate — a re-registration
 * of the same pair refreshes platform / app_version / bundle_id / topic /
 * updated_at but never throws a UNIQUE-constraint error.
 *
 * The route is mounted at /api/devices in src/index.ts behind the same
 * Better Auth requireAuth middleware sync.ts uses (canonical pattern —
 * no parallel auth check rolled here).
 *
 * Wire body shape matches RishiAPI/Endpoints/DevicesAPI.swift snake_case
 * CodingKeys. The `env` column defaults to "production" because the iOS
 * body does NOT carry an env field today (the DEBUG-vs-PRODUCTION APNs
 * environment is selectable later if we need a sandbox path).
 */

const BodySchema = z.object({
  device_token: z.string().min(40).max(200),
  platform: z.enum(["ios", "ipados", "macos-catalyst"]),
  app_version: z.string().min(1).max(40),
  bundle_id: z.string().min(1).max(120),
  topic: z.string().min(1).max(120),
});

export const devicesRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

devicesRoutes.post("/register", requireAuth, requireAiDataConsent, async (c) => {
  const raw = await c.req.json().catch(() => null);
  const parsed = BodySchema.safeParse(raw);
  if (!parsed.success) {
    return c.json({ error: "bad_request", detail: parsed.error.message }, 400);
  }

  const userId = c.get("userId");
  const now = new Date();
  const db = createDb(c.env.DB);
  const id = crypto.randomUUID();

  const row = {
    id,
    userId,
    deviceToken: parsed.data.device_token,
    platform: parsed.data.platform,
    appVersion: parsed.data.app_version,
    bundleId: parsed.data.bundle_id,
    topic: parsed.data.topic,
    env: "production" as const,
    createdAt: now,
    updatedAt: now,
  };

  const inserted = await db
    .insert(devices)
    .values(row)
    .onConflictDoUpdate({
      target: [devices.userId, devices.deviceToken],
      set: {
        platform: row.platform,
        appVersion: row.appVersion,
        bundleId: row.bundleId,
        topic: row.topic,
        updatedAt: now,
      },
    })
    .returning({ id: devices.id, createdAt: devices.createdAt })
    .get();

  return c.json({
    device_id: inserted?.id ?? id,
    registered_at:
      ((inserted?.createdAt ?? now).getTime() - REFERENCE_DATE_OFFSET_MS) /
      1000,
  });
});
