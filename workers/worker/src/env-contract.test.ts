import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const requiredProductionSecrets = [
  "ACCESS_TOKEN_SECRET",
  "APPLE_APNS_KEY_ID",
  "APPLE_APNS_KEY_P8",
  "APPLE_IDENTITY_RETENTION_SECRET_CURRENT",
  "APPLE_SIWA_CLIENT_ID",
  "APPLE_SIWA_KEY_ID",
  "APPLE_SIWA_PRIVATE_KEY",
  "APPLE_TEAM_ID",
  "APPLE_TRANSACTION_HASH_SECRET",
  "BETTER_AUTH_SECRET",
  "CLOUDFLARE_ACCOUNT_ID",
  "DEEPGRAM_KEY",
  "ELEVEN_LABS_API_KEY",
  "GOOGLE_CLIENT_ID",
  "GOOGLE_CLIENT_SECRET",
  "JWT_PRIVATE_KEY",
  "OPENAI_API_KEY",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "REFRESH_TOKEN_SECRET",
  "RESEND_API_KEY",
  "SHARING_INTERNAL_SECRET",
  "SIWA_TOKEN_ENCRYPTION_SECRET",
  "STRIPE_SECRET_KEY",
  "STRIPE_WEBHOOK_SECRET",
  "UPSTASH_REDIS_REST_TOKEN",
  "UPSTASH_REDIS_REST_URL",
  "VOICE_SESSION_NONCE_SECRET",
];

describe("Worker Env contract", () => {
  it("declares exactly the production secrets required by Wrangler", () => {
    const config = readFileSync(
      new URL("../wrangler.jsonc", import.meta.url),
      "utf8",
    );

    const requiredBlock = config.match(
      /"secrets"\s*:\s*\{\s*"required"\s*:\s*\[([\s\S]*?)\]\s*\}/,
    )?.[1];

    expect(requiredBlock).toBeDefined();
    expect(requiredBlock?.match(/"[A-Z0-9_]+"/g)?.map((name) => name.slice(1, -1))).toEqual(
      requiredProductionSecrets,
    );
  });

  it("keeps non-production controls optional outside Wrangler's required secrets", () => {
    const envDeclaration = new URL("./env.d.ts", import.meta.url);

    expect(existsSync(envDeclaration)).toBe(true);
    if (!existsSync(envDeclaration)) return;

    const source = readFileSync(envDeclaration, "utf8");
    expect(source).toMatch(/declare global\s*\{\s*interface Env\s*\{/);
    expect(source).toMatch(/SENTRY_DSN\?: string/);
    expect(source).toMatch(/ENABLE_TEST_AUTH\?: string/);
    expect(source).toMatch(/TEST_AUTH_SECRET\?: string/);
    expect(source).toMatch(/ENABLE_OPS_ADMIN\?: string/);
    expect(source).toMatch(/OPS_ADMIN_SECRET\?: string/);
  });
});
