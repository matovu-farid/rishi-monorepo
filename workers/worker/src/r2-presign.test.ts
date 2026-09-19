import { describe, it, expect } from "vitest";
import { signR2Url } from "./r2-presign";

// NOTE: this file intentionally does NOT mock aws4fetch — it exercises the real
// SigV4 query signer so it catches signing-shape regressions that a mock hides.
const env = {
  CLOUDFLARE_ACCOUNT_ID: "b700cf80e995aacbfa27aaa8d2084d18",
  R2_ACCESS_KEY_ID: "test-access-key-id",
  R2_SECRET_ACCESS_KEY: "test-secret-access-key",
  BOOK_STORAGE_BUCKET_NAME: "rishi-books",
};

describe("signR2Url — presigned R2 URL shape", () => {
  it("puts X-Amz-Expires in the query at the requested value", async () => {
    const url = new URL(
      await signR2Url(env, { key: "books/u/b.epub", method: "PUT", expiresSec: 300 }),
    );
    expect(url.searchParams.get("X-Amz-Expires")).toBe("300");
  });

  it("signs ONLY the host header (x-amz-expires must not be a signed header)", async () => {
    // If X-Amz-Expires is signed as a header, R2 expects the PUT to replay it;
    // the client never does -> SignatureDoesNotMatch. SignedHeaders must be 'host'.
    const url = new URL(
      await signR2Url(env, { key: "books/u/b.epub", method: "PUT", expiresSec: 300 }),
    );
    expect(url.searchParams.get("X-Amz-SignedHeaders")).toBe("host");
  });

  it.each(["rishi-books", "rishi-books-e2e"])("signs a PUT URL for the configured %s bucket", async (bucketName) => {
    const url = new URL(
      await signR2Url(
        { ...env, BOOK_STORAGE_BUCKET_NAME: bucketName },
        { key: "books/u/b.pdf", method: "PUT", expiresSec: 600 },
      ),
    );
    expect(url.host).toBe(`${env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com`);
    expect(url.pathname).toBe(`/${bucketName}/books/u/b.pdf`);
    expect(url.searchParams.get("X-Amz-Signature")).toBeTruthy();
    expect(url.searchParams.get("X-Amz-Credential")).toContain("/auto/s3/aws4_request");
  });

  it.each(["", undefined, null, new String("rishi-books")])("rejects a non-string or unsafe configured bucket name before signing", async (bucketName) => {
    await expect(
      signR2Url(
        { ...env, BOOK_STORAGE_BUCKET_NAME: bucketName } as unknown as typeof env,
        { key: "books/u/b.pdf", method: "PUT", expiresSec: 600 },
      ),
    ).rejects.toThrow("BOOK_STORAGE_BUCKET_NAME");
  });
});
