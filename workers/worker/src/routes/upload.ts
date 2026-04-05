import { Hono } from "hono";
import { eq } from "drizzle-orm";
import { AwsClient } from "aws4fetch";
import type { CloudflareBindings } from "../index";
import { requireWorkerAuth } from "../index";
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

// ─── POST /upload-url ──────────────────────────────────────────────────────────
// Returns a presigned PUT URL for direct R2 upload, or {exists: true} for dedup.
// Does NOT sign Content-Type in headers (per research pitfall -- signQuery only).
uploadRoutes.post("/upload-url", requireWorkerAuth, async (c) => {
  const body = await c.req.json<UploadUrlRequest>();
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  // Check for existing file with same hash (global dedup across all users)
  const existing = await db
    .select({ fileR2Key: books.fileR2Key })
    .from(books)
    .where(eq(books.fileHash, body.fileHash))
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
    aws: { signQuery: true },
  });

  const response: UploadUrlResponse = {
    exists: false,
    uploadUrl: signed.url.toString(),
    r2Key,
    expiresIn: 3600,
  };
  return c.json(response);
});

// ─── POST /download-url ────────────────────────────────────────────────────────
// Returns a presigned GET URL for downloading a file from R2.
uploadRoutes.post("/download-url", requireWorkerAuth, async (c) => {
  const body = await c.req.json<DownloadUrlRequest>();

  const bucketUrl = `https://${c.env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com/rishi-books/${body.r2Key}`;

  const aws = new AwsClient({
    accessKeyId: c.env.R2_ACCESS_KEY_ID,
    secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });

  const signed = await aws.sign(new Request(bucketUrl, { method: "GET" }), {
    aws: { signQuery: true },
  });

  const response: DownloadUrlResponse = {
    downloadUrl: signed.url.toString(),
    expiresIn: 3600,
  };
  return c.json(response);
});
