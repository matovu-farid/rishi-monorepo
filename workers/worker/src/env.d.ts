/**
 * Wrangler's generated Env interface describes vars and bindings, but not
 * secrets uploaded with `wrangler secret put`. Keep the secret names typed
 * here without putting values in source or in wrangler.jsonc.
 */
interface Env {
  APPLE_APNS_KEY_ID?: string;
  APPLE_APNS_KEY_P8?: string;
  APPLE_IDENTITY_RETENTION_SECRET_CURRENT?: string;
  APPLE_IDENTITY_RETENTION_SECRET_PREVIOUS?: string;
  APPLE_SIWA_CLIENT_ID: string;
  APPLE_SIWA_KEY_ID: string;
  APPLE_SIWA_PRIVATE_KEY: string;
  APPLE_TEAM_ID: string;
  APPLE_TRANSACTION_HASH_SECRET?: string;
  APPLE_TRANSACTION_HASH_SECRET_PREVIOUS?: string;
  CLOUDFLARE_ACCOUNT_ID: string;
  DEV_BYPASS_SECRET?: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  SENTRY_DSN?: string;
  SHARING_INTERNAL_SECRET: string;
  SIWA_TOKEN_ENCRYPTION_SECRET?: string;
  UPSTASH_REDIS_REST_TOKEN: string;
  UPSTASH_REDIS_REST_URL: string;
}
