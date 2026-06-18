import { AwsClient } from "aws4fetch";

// Minimal structural env — avoids a runtime import of CloudflareBindings so the
// signer is unit-testable with the real aws4fetch (no Worker app graph pulled in).
export interface R2SigningEnv {
  CLOUDFLARE_ACCOUNT_ID: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
}

const R2_BUCKET = "rishi-books";

/**
 * Generate a SigV4 query-signed (presigned) R2 URL for a direct client
 * upload/download against the `rishi-books` bucket.
 */
export async function signR2Url(
  env: R2SigningEnv,
  opts: { key: string; method: "PUT" | "GET"; expiresSec: number },
): Promise<string> {
  const url = new URL(
    `https://${env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${opts.key}`,
  );
  // X-Amz-Expires MUST be a query param set BEFORE signing. Passing it as a
  // header makes aws4fetch fold it into X-Amz-SignedHeaders (host;x-amz-expires)
  // — which a direct PUT/GET can't replay — so R2 returns SignatureDoesNotMatch.
  url.searchParams.set("X-Amz-Expires", String(opts.expiresSec));

  const aws = new AwsClient({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });

  const signed = await aws.sign(new Request(url, { method: opts.method }), {
    aws: { signQuery: true },
  });
  return signed.url.toString();
}
