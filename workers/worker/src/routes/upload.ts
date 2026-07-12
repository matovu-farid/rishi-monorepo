import { Hono } from "hono";
import { eq, and, count, sum } from "drizzle-orm";

import { createDb } from "../db/drizzle";
import { books } from "@rishi/shared/schema";
import { signR2Url } from "../r2-presign";
import { requireAuth } from "../middleware";

// Defaults applied when the corresponding wrangler var is unset.
const DEFAULT_BOOK_MAX_PER_USER = 500;
const DEFAULT_BOOK_MAX_USER_BYTES = 10_737_418_240; // 10 GB

// Reference offset constant: 978_307_200_000 ms is the gap between the Unix
// epoch (1970-01-01) and Apple's Foundation reference date (2001-01-01). iOS
// `JSONDecoder()` with `.deferredToDate` (verified in
// apps/apple/Packages/RishiAPI/Sources/RishiAPI/WorkerClient.swift:96) decodes
// JSON numbers as seconds-since-2001. Every Date emitted from this worker MUST
// use this conversion — see plan 17-10 audit.
const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;

// Presigned upload URL expiry — 5 minutes is enough for the iOS uploader to
// PUT a single book file, short enough that a leaked URL is low risk.
const UPLOAD_URL_EXPIRES_SEC = 300;

// Presigned download URL expiry — 10 minutes covers large EPUB/PDF downloads
// on flaky mobile networks.
const DOWNLOAD_URL_EXPIRES_SEC = 600;

function getLimits(env: Env) {
  return {
    perUserCount: Number(env.BOOK_MAX_PER_USER) || DEFAULT_BOOK_MAX_PER_USER,
    perUserBytes:
      Number(env.BOOK_MAX_USER_BYTES) || DEFAULT_BOOK_MAX_USER_BYTES,
  };
}

export const uploadRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

/**
 * Validates that an R2 key is safely scoped under the given prefix
 * with no path traversal tricks.
 *
 * Rejects:
 *  - keys containing ".." (parent-directory traversal)
 *  - keys containing "%" (URL-encoded traversal like %2e%2e)
 *  - keys containing null bytes
 *  - keys that, after normalization, escape the expected prefix
 */
function isR2KeySafe(r2Key: string, expectedPrefix: string): boolean {
  // Reject obvious traversal / encoding tricks
  if (r2Key.includes("..") || r2Key.includes("%") || r2Key.includes("\0")) {
    return false;
  }

  // Must start with the expected prefix
  if (!r2Key.startsWith(expectedPrefix)) {
    return false;
  }

  // Normalize by collapsing consecutive slashes and resolving "." segments,
  // then re-check the prefix to catch anything creative.
  const segments = r2Key.split("/").filter((s) => s !== "" && s !== ".");
  const normalized = segments.join("/") + (r2Key.endsWith("/") ? "/" : "");
  if (!normalized.startsWith(expectedPrefix)) {
    return false;
  }

  return true;
}

// ─── POST /upload-url ──────────────────────────────────────────────────────────
// Returns a presigned PUT URL for direct R2 upload, scoped to the
// iOS-supplied R2 key. iOS contract (PH17-08 Gap 3):
//
//   Request:  { key: "books/<userId>/<bookId>.<ext>", content_type: "<mime>" }
//   Response: { url: "<signed-url>", expires_at: <seconds-since-2001 number> }
//
// See apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/SyncAPI.swift
// (PresignedURLResponse, SyncUploadURLEndpoint.Body) and BookUploader.swift:54.
//
// Key safety: `body.key` MUST begin with `books/<authedUserId>/` and contain no
// `..`/`%`/null-byte tricks (isR2KeySafe). This prevents the client from
// uploading on behalf of another user.
//
// Storage caps: per-user book count + per-user bytes are still enforced from
// the DB. iOS no longer passes fileSize, so the per-file size precheck is
// skipped — we rely on R2's per-object size ceiling and the per-user bytes
// query (which sums existing books.file_size rows).
//
// Does NOT sign Content-Type in headers (signQuery only) so the client's PUT
// can use whatever Content-Type it likes without breaking the signature.
uploadRoutes.post("/upload-url", requireAuth, async (c) => {
  const body = await c.req
    .json<{ key?: unknown; content_type?: unknown }>()
    .catch(() => null);
  if (
    !body ||
    typeof body.key !== "string" ||
    typeof body.content_type !== "string"
  ) {
    return c.json({ error: "bad_request" }, 400);
  }

  const userId = c.get("userId");

  // ─── Key prefix safety (per-user isolation) ──────────────────────────────
  const expectedPrefix = `books/${userId}/`;
  if (!isR2KeySafe(body.key, expectedPrefix)) {
    return c.json({ error: "Forbidden: invalid key" }, 403);
  }

  const limits = getLimits(c.env);
  const db = createDb(c.env.DB);

  // ─── Per-user book count cap ─────────────────────────────────────────────
  const countResult = await db
    .select({ n: count() })
    .from(books)
    .where(and(eq(books.userId, userId), eq(books.isDeleted, false)))
    .get();
  const currentCount = Number(countResult?.n ?? 0);
  if (currentCount >= limits.perUserCount) {
    return c.json(
      {
        error: `User has reached the maximum number of books (${limits.perUserCount})`,
        code: "BOOK_LIMIT_REACHED",
        limit: limits.perUserCount,
        current: currentCount,
      },
      507,
    );
  }

  // ─── Per-user storage bytes cap ──────────────────────────────────────────
  // iOS no longer ships fileSize, so we cannot pre-add the incoming file. We
  // gate purely on the EXISTING sum: if the user is already at or over the
  // cap, reject. The next push that lands a books row with file_size will
  // catch any overflow before the user can upload again.
  const sumResult = await db
    .select({ total: sum(books.fileSize) })
    .from(books)
    .where(and(eq(books.userId, userId), eq(books.isDeleted, false)))
    .get();
  const currentBytes = Number(sumResult?.total ?? 0);
  if (currentBytes >= limits.perUserBytes) {
    return c.json(
      {
        error: `User would exceed storage limit of ${limits.perUserBytes} bytes`,
        code: "STORAGE_LIMIT_REACHED",
        limit: limits.perUserBytes,
        current: currentBytes,
      },
      507,
    );
  }

  // ─── Sign the PUT URL against the iOS-supplied key ──────────────────────
  const signedUrl = await signR2Url(c.env, {
    key: body.key,
    method: "PUT",
    expiresSec: UPLOAD_URL_EXPIRES_SEC,
  });

  // Date wire format = seconds since 2001-01-01 reference date — see
  // routes/changes.ts and routes/devices.test.ts.
  const expiresAtSeconds =
    (Date.now() + UPLOAD_URL_EXPIRES_SEC * 1000 - REFERENCE_DATE_OFFSET_MS) /
    1000;

  return c.json({
    url: signedUrl,
    expires_at: expiresAtSeconds,
  });
});

// ─── POST /download-url ────────────────────────────────────────────────────────
// Returns a presigned GET URL for downloading a file from R2, scoped to the
// iOS-supplied R2 key. iOS contract (PH17-09 Gap 4):
//
//   Request:  { key: "books/<userId>/<bookId>.<ext>" }
//   Response: { url: "<signed-url>", expires_at: <seconds-since-2001 number> }
//
// See apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/SyncAPI.swift
// (PresignedURLResponse, SyncDownloadURLEndpoint.Body) and the
// DownloadCoordinator that consumes PresignedURLResponse.
//
// Key safety: `body.key` MUST begin with `books/<authedUserId>/` and contain no
// `..`/`%`/null-byte tricks (isR2KeySafe). This prevents the client from
// downloading another user's book file.
uploadRoutes.post("/download-url", requireAuth, async (c) => {
  const body = await c.req.json<{ key?: unknown }>().catch(() => null);
  if (!body || typeof body.key !== "string") {
    return c.json({ error: "Forbidden: invalid key" }, 403);
  }

  const userId = c.get("userId");

  // ─── Key prefix safety (per-user isolation) ──────────────────────────────
  const expectedPrefix = `books/${userId}/`;
  if (!isR2KeySafe(body.key, expectedPrefix)) {
    return c.json({ error: "Forbidden: invalid key" }, 403);
  }

  // ─── Sign the GET URL against the iOS-supplied key ──────────────────────
  const signedUrl = await signR2Url(c.env, {
    key: body.key,
    method: "GET",
    expiresSec: DOWNLOAD_URL_EXPIRES_SEC,
  });

  // Date wire format = seconds since 2001-01-01 reference date — see
  // routes/changes.ts and routes/devices.test.ts.
  const expiresAtSeconds =
    (Date.now() + DOWNLOAD_URL_EXPIRES_SEC * 1000 - REFERENCE_DATE_OFFSET_MS) /
    1000;

  return c.json({
    url: signedUrl,
    expires_at: expiresAtSeconds,
  });
});
