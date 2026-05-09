import { Hono } from "hono";
import { eq, and } from "drizzle-orm";
import { AwsClient } from "aws4fetch";
import type { CloudflareBindings } from "../index";
import { requireClerkAuth } from "../index";
import { createDb } from "../db/drizzle";
import { books } from "@rishi/shared/schema";
import type {
  UploadUrlRequest,
  UploadUrlResponse,
  DownloadUrlRequest,
  DownloadUrlResponse,
} from "@rishi/shared/sync-types";

export const uploadRoutes = new Hono<{
  Bindings: CloudflareBindings;
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
// Returns a presigned PUT URL for direct R2 upload, or {exists: true} for dedup.
// Does NOT sign Content-Type in headers (per research pitfall -- signQuery only).
uploadRoutes.post("/upload-url", requireClerkAuth, async (c) => {
  const body = await c.req.json<UploadUrlRequest>();

  if (!body.fileHash || !/^[a-fA-F0-9]{64}$/.test(body.fileHash)) {
    return c.json({ error: "Invalid fileHash format" }, 400);
  }

  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  // Check for existing file with same hash scoped to this user
  const existing = await db
    .select({ fileR2Key: books.fileR2Key })
    .from(books)
    .where(and(eq(books.fileHash, body.fileHash), eq(books.userId, userId)))
    .get();

  if (existing?.fileR2Key) {
    const response: UploadUrlResponse = {
      exists: true,
      r2Key: existing.fileR2Key,
    };
    return c.json(response);
  }

  // Generate R2 key and presigned PUT URL
  const r2Key = `books/${userId}/${body.fileHash}`;
  const bucketUrl = `https://${c.env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com/rishi-books/${r2Key}`;

  const aws = new AwsClient({
    accessKeyId: c.env.R2_ACCESS_KEY_ID,
    secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });

  // Sign with signQuery: true and bare Request (no Content-Type header)
  // to avoid signature mismatch when client sends different Content-Type
  const signed = await aws.sign(new Request(bucketUrl, { method: "PUT" }), {
    aws: { signQuery: true, datetime: new Date().toISOString().replace(/[:-]|\.\d{3}/g, '') },
    headers: { "X-Amz-Expires": "300" },
  });

  const response: UploadUrlResponse = {
    exists: false,
    uploadUrl: signed.url.toString(),
    r2Key,
    expiresIn: 300,
  };
  return c.json(response);
});

// ─── POST /download-url ────────────────────────────────────────────────────────
// Returns a presigned GET URL for downloading a file from R2.
uploadRoutes.post("/download-url", requireClerkAuth, async (c) => {
  const body = await c.req.json<DownloadUrlRequest>();
  const userId = c.get("userId");

  // Validate that the r2Key is scoped to this user's prefix to prevent path traversal
  const expectedPrefix = `books/${userId}/`;
  if (!body.r2Key || !isR2KeySafe(body.r2Key, expectedPrefix)) {
    return c.json({ error: "Forbidden: invalid r2Key" }, 403);
  }

  const bucketUrl = `https://${c.env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com/rishi-books/${body.r2Key}`;

  const aws = new AwsClient({
    accessKeyId: c.env.R2_ACCESS_KEY_ID,
    secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });

  const signed = await aws.sign(new Request(bucketUrl, { method: "GET" }), {
    aws: { signQuery: true, datetime: new Date().toISOString().replace(/[:-]|\.\d{3}/g, '') },
    headers: { "X-Amz-Expires": "600" },
  });

  const response: DownloadUrlResponse = {
    downloadUrl: signed.url.toString(),
    expiresIn: 600,
  };
  return c.json(response);
});
