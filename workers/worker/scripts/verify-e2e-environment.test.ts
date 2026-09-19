import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  verifyE2EEnvironment,
  type WranglerConfig,
} from "./verify-e2e-environment";

const temporaryDirectories: string[] = [];

const productionDatabaseId = "970159b7-ca91-49c1-bae8-feb43b24a7e6";
const productionKvIds = [
  "12eb084c99f44bebafcf1143bc457f58",
  "34c4751c01a94f22a04a211f4eec8d54",
];
const productionKvPreviewIds = [
  "49a43a76aac747ad8472856f33e1eeda",
  "76cdf05f101043a892c02ce590e4a694",
];
const migrationPattern =
  "drizzle/migrations/{*.sql,20260803145911_classy_sleepwalker/migration.sql,20260808181936_book_sharing/migration.sql,20260812135706_book_sharing_access/migration.sql,20260813110000_pregenerated_share_links/migration.sql,20260820112725_session_invites_from_prod_session_only/migration.sql,20260820121338_session_invites_idempotency/migration.sql}";

function apiConfig(): WranglerConfig {
  return {
    $schema: "node_modules/wrangler/config-schema.json",
    name: "rishi-worker",
    main: "src/index.ts",
    compatibility_date: "2025-11-17",
    compatibility_flags: ["nodejs_als", "nodejs_compat"],
    version_metadata: { binding: "CF_VERSION_METADATA" },
    services: [{ binding: "SHARING_WORKER", service: "rishi-sharing-worker" }],
    d1_databases: [{
      binding: "DB",
      database_name: "rishi",
      database_id: productionDatabaseId,
      migrations_dir: "drizzle/migrations",
      migrations_pattern: migrationPattern,
    }],
    r2_buckets: [
      { binding: "APPLE", bucket_name: "apple", remote: true },
      { binding: "BOOK_STORAGE", bucket_name: "rishi-books" },
      { binding: "TTS_CACHE", bucket_name: "rishi-tts-cache" },
      { binding: "apple_dev", bucket_name: "apple-dev" },
    ],
    kv_namespaces: [
      { binding: "RISHI_DESKTOP_STATE", id: productionKvIds[0], preview_id: "49a43a76aac747ad8472856f33e1eeda" },
      { binding: "RATE_LIMIT_KV", id: productionKvIds[1], preview_id: "76cdf05f101043a892c02ce590e4a694" },
    ],
    durable_objects: {
      bindings: [{ name: "USER_USAGE_LEDGER", class_name: "UserUsageLedger" }],
    },
    migrations: [{ tag: "v1", new_sqlite_classes: ["UserUsageLedger"] }],
    rules: [{ type: "Text", globs: ["**/*.sql"], fallthrough: true }],
    vars: {
      PUBLIC_API_URL: "https://api.fidexa.org",
      PUBLIC_WEB_URL: "https://rishi.fidexa.org",
      SHARING_WORKER_WS_URL: "wss://sharing.fidexa.org",
      BOOK_STORAGE_BUCKET_NAME: "rishi-books",
      BOOK_MAX_FILE_BYTES: "838860800",
      BOOK_MAX_PER_USER: "500",
      BOOK_MAX_USER_BYTES: "10737418240",
    },
    secrets: {
      required: [
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
      ],
    },
    routes: [{ pattern: "api.fidexa.org", custom_domain: true }],
    triggers: { crons: ["17 2 * * *", "* * * * *"] },
    env: {
      e2e: {
        name: "rishi-worker-e2e",
        compatibility_date: "2025-11-17",
        compatibility_flags: ["nodejs_als", "nodejs_compat"],
        version_metadata: { binding: "CF_VERSION_METADATA" },
        services: [{ binding: "SHARING_WORKER", service: "rishi-sharing-worker-e2e" }],
        d1_databases: [{
          binding: "DB",
          database_name: "rishi-e2e",
          database_id: "11111111-2222-4333-8444-555555555555",
          migrations_dir: "drizzle/migrations",
          migrations_pattern: migrationPattern,
        }],
        r2_buckets: [
          { binding: "APPLE", bucket_name: "apple-e2e", remote: true },
          { binding: "BOOK_STORAGE", bucket_name: "rishi-books-e2e" },
          { binding: "TTS_CACHE", bucket_name: "rishi-tts-cache-e2e" },
          { binding: "apple_dev", bucket_name: "apple-dev-e2e" },
        ],
        kv_namespaces: [
          { binding: "RISHI_DESKTOP_STATE", id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
          { binding: "RATE_LIMIT_KV", id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        ],
        durable_objects: {
          bindings: [{ name: "USER_USAGE_LEDGER", class_name: "UserUsageLedger" }],
        },
        migrations: [{ tag: "v1", new_sqlite_classes: ["UserUsageLedger"] }],
        rules: [{ type: "Text", globs: ["**/*.sql"], fallthrough: true }],
        vars: {
          PUBLIC_API_URL: "https://api-e2e.fidexa.org",
          PUBLIC_WEB_URL: "https://api-e2e.fidexa.org",
          SHARING_WORKER_WS_URL: "wss://sharing-e2e.fidexa.org",
          ENABLE_TEST_AUTH: "true",
          CLOUDFLARE_ACCOUNT_ID: "b700cf80e995aacbfa27aaa8d2084d18",
          BOOK_STORAGE_BUCKET_NAME: "rishi-books-e2e",
          BOOK_MAX_FILE_BYTES: "838860800",
          BOOK_MAX_PER_USER: "500",
          BOOK_MAX_USER_BYTES: "10737418240",
        },
        secrets: {
          required: [
            "TEST_AUTH_SECRET",
            "BETTER_AUTH_SECRET",
            "SHARING_INTERNAL_SECRET",
            "ACCESS_TOKEN_SECRET",
            "REFRESH_TOKEN_SECRET",
            "VOICE_SESSION_NONCE_SECRET",
            "R2_ACCESS_KEY_ID",
            "R2_SECRET_ACCESS_KEY",
          ],
        },
        routes: [{ pattern: "api-e2e.fidexa.org", custom_domain: true }],
      },
    },
  };
}

function sharingConfig(): WranglerConfig {
  return {
    $schema: "node_modules/wrangler/config-schema.json",
    name: "rishi-sharing-worker",
    main: "src/index.ts",
    compatibility_date: "2026-05-30",
    compatibility_flags: ["nodejs_compat"],
    observability: { enabled: true, head_sampling_rate: 1 },
    durable_objects: {
      bindings: [
        { name: "SESSION_ROOM", class_name: "SessionRoom" },
        { name: "APPLE_SESSION_ROOM", class_name: "AppleSessionRoom" },
      ],
    },
    migrations: [
      { tag: "v1", new_sqlite_classes: ["SessionRoom"] },
      { tag: "v2", new_sqlite_classes: ["AppleSessionRoom"] },
    ],
    vars: { AUTH_BASE_URL: "https://api.fidexa.org" },
    routes: [{ pattern: "sharing.fidexa.org", custom_domain: true }],
    env: {
      production: {
        name: "rishi-sharing-worker",
        compatibility_date: "2026-05-30",
        compatibility_flags: ["nodejs_compat"],
        observability: { enabled: true, head_sampling_rate: 1 },
        durable_objects: {
          bindings: [
            { name: "SESSION_ROOM", class_name: "SessionRoom" },
            { name: "APPLE_SESSION_ROOM", class_name: "AppleSessionRoom" },
          ],
        },
        migrations: [
          { tag: "v1", new_sqlite_classes: ["SessionRoom"] },
          { tag: "v2", new_sqlite_classes: ["AppleSessionRoom"] },
        ],
        vars: { AUTH_BASE_URL: "https://api.fidexa.org" },
        routes: [{ pattern: "sharing.fidexa.org", custom_domain: true }],
      },
      e2e: {
        name: "rishi-sharing-worker-e2e",
        compatibility_date: "2026-05-30",
        compatibility_flags: ["nodejs_compat"],
        observability: { enabled: true, head_sampling_rate: 1 },
        durable_objects: {
          bindings: [
            { name: "SESSION_ROOM", class_name: "SessionRoom" },
            { name: "APPLE_SESSION_ROOM", class_name: "AppleSessionRoom" },
          ],
        },
        migrations: [
          { tag: "v1", new_sqlite_classes: ["SessionRoom"] },
          { tag: "v2", new_sqlite_classes: ["AppleSessionRoom"] },
        ],
        vars: { AUTH_BASE_URL: "https://api-e2e.fidexa.org", TEST_AUTH_ALLOWED: "1" },
        routes: [{ pattern: "sharing-e2e.fidexa.org", custom_domain: true }],
        secrets: { required: ["WORKER_HMAC_SECRET"] },
      },
    },
  };
}

function writeFixture(api: WranglerConfig, sharing: WranglerConfig): { apiConfigPath: string; sharingConfigPath: string } {
  const directory = mkdtempSync(join(tmpdir(), "rishi-e2e-verifier-"));
  temporaryDirectories.push(directory);
  const apiConfigPath = join(directory, "wrangler.jsonc");
  const sharingConfigPath = join(directory, "sharing-wrangler.jsonc");
  writeFileSync(apiConfigPath, `// JSONC fixture\n${JSON.stringify(api, null, 2)}\n`);
  writeFileSync(sharingConfigPath, `/* JSONC fixture */\n${JSON.stringify(sharing, null, 2)}\n`);
  return { apiConfigPath, sharingConfigPath };
}

function verify(api = apiConfig(), sharing = sharingConfig()) {
  const fixture = writeFixture(api, sharing);
  const e2e = api.env!.e2e;
  return verifyE2EEnvironment({
    ...fixture,
    approvedResources: {
      d1DatabaseId: e2e.d1_databases![0].database_id,
      kvNamespaceIds: {
        RISHI_DESKTOP_STATE: e2e.kv_namespaces![0].id,
        RATE_LIMIT_KV: e2e.kv_namespaces![1].id,
      },
    },
  });
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("verifyE2EEnvironment", () => {
  it("accepts a complete isolated fixture and enforces bucket-variable equality", () => {
    const result = verify();
    expect(result.errors).toEqual([]);
    expect(result.summary).toContain("rishi-books");
    expect(result.summary).toContain("rishi-books-e2e");
  });

  it.each([
    ["production D1 ID", (config: WranglerConfig) => { config.d1_databases![0].database_id = "11111111-2222-4333-8444-555555555555"; }, "production API D1 database ID"],
    ["production D1 name", (config: WranglerConfig) => { config.d1_databases![0].database_name = "rishi-e2e"; }, "production API D1 database name"],
    ["production R2 bucket", (config: WranglerConfig) => { config.r2_buckets![0].bucket_name = "apple-e2e"; }, "production API R2 bucket APPLE"],
    ["production KV ID", (config: WranglerConfig) => { config.kv_namespaces![0].id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }, "production API KV namespace ID"],
    ["production KV preview ID", (config: WranglerConfig) => { config.kv_namespaces![0].preview_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }, "production API KV preview ID"],
    ["production service target", (config: WranglerConfig) => { config.services![0].service = "rishi-sharing-worker-e2e"; }, "production API service target"],
    ["production custom domain", (config: WranglerConfig) => { config.routes![0].pattern = "api-e2e.fidexa.org"; }, "production API custom domain"],
    ["missing E2E DO binding", (config: WranglerConfig) => { delete config.env!.e2e.durable_objects; }, "E2E API Durable Object binding"],
    ["missing E2E DO migration", (config: WranglerConfig) => { config.env!.e2e.migrations = []; }, "E2E API Durable Object migration"],
    ["E2E cron", (config: WranglerConfig) => { config.env!.e2e.triggers = { crons: ["* * * * *"] }; }, "E2E API must not declare cron"],
    ["missing E2E gate", (config: WranglerConfig) => { delete config.env!.e2e.vars.ENABLE_TEST_AUTH; }, "E2E API ENABLE_TEST_AUTH is required"],
    ["production gate", (config: WranglerConfig) => { config.vars.ENABLE_TEST_AUTH = "true"; }, "production API must not enable test auth"],
    ["duplicate KV IDs", (config: WranglerConfig) => { config.env!.e2e.kv_namespaces![1].id = config.env!.e2e.kv_namespaces![0].id; }, "E2E API KV namespace IDs must be distinct"],
    ["E2E production KV ID", (config: WranglerConfig) => { config.env!.e2e.kv_namespaces![0].id = productionKvIds[0]; }, "E2E API KV namespace ID RISHI_DESKTOP_STATE must not match a production ID"],
    ["E2E production KV preview ID", (config: WranglerConfig) => { config.env!.e2e.kv_namespaces![0].id = productionKvPreviewIds[0]; }, "E2E API KV namespace ID RISHI_DESKTOP_STATE must not match a production preview ID"],
    ["account ID", (config: WranglerConfig) => { config.env!.e2e.vars.CLOUDFLARE_ACCOUNT_ID = "wrong-account"; }, "CLOUDFLARE_ACCOUNT_ID"],
    ["E2E API origin", (config: WranglerConfig) => { config.env!.e2e.vars.PUBLIC_API_URL = "https://api.fidexa.org"; }, "E2E API PUBLIC_API_URL"],
    ["E2E web origin", (config: WranglerConfig) => { config.env!.e2e.vars.PUBLIC_WEB_URL = "https://api-e2e.fidexa.org/path"; }, "E2E API PUBLIC_WEB_URL"],
    ["E2E sharing origin", (config: WranglerConfig) => { config.env!.e2e.vars.SHARING_WORKER_WS_URL = "wss://sharing.fidexa.org"; }, "E2E API SHARING_WORKER_WS_URL"],
    ["sharing auth origin", (_config: WranglerConfig, sharing: WranglerConfig) => { sharing.env!.e2e.vars.AUTH_BASE_URL = "https://api.fidexa.org"; }, "E2E sharing AUTH_BASE_URL"],
    ["missing production bucket variable", (config: WranglerConfig) => { delete config.vars.BOOK_STORAGE_BUCKET_NAME; }, "production BOOK_STORAGE_BUCKET_NAME"],
    ["wrong E2E bucket variable", (config: WranglerConfig) => { config.env!.e2e.vars.BOOK_STORAGE_BUCKET_NAME = "rishi-books"; }, "E2E BOOK_STORAGE_BUCKET_NAME"],
    ["missing E2E bucket binding", (config: WranglerConfig) => { config.env!.e2e.r2_buckets = config.env!.e2e.r2_buckets!.filter((bucket) => bucket.binding !== "BOOK_STORAGE"); }, "E2E API R2 binding BOOK_STORAGE"],
    ["duplicate R2 binding", (config: WranglerConfig) => { config.env!.e2e.r2_buckets![3].binding = "BOOK_STORAGE"; }, "E2E API R2 binding names must be unique"],
    ["duplicate KV binding", (config: WranglerConfig) => { config.env!.e2e.kv_namespaces![1].binding = "RISHI_DESKTOP_STATE"; }, "E2E API KV binding names must be unique"],
    ["E2E sharing service binding", (_config: WranglerConfig, sharing: WranglerConfig) => { sharing.env!.e2e.services = [{ binding: "API", service: "rishi-worker-e2e" }]; }, "E2E sharing Worker must not declare service bindings"],
    ["missing API metadata", (config: WranglerConfig) => { delete config.env!.e2e.version_metadata; }, "E2E API CF_VERSION_METADATA"],
    ["missing SQL text rule", (config: WranglerConfig) => { config.env!.e2e.rules = []; }, "E2E API SQL text rule"],
    ["API compatibility", (config: WranglerConfig) => { config.env!.e2e.compatibility_date = "2024-01-01"; }, "API compatibility date"],
    ["sharing compatibility", (_config: WranglerConfig, sharing: WranglerConfig) => { sharing.env!.e2e.compatibility_flags = []; }, "sharing compatibility flags"],
    ["sharing observability", (_config: WranglerConfig, sharing: WranglerConfig) => { delete sharing.env!.e2e.observability; }, "E2E sharing observability"],
    ["API required secret", (config: WranglerConfig) => { config.env!.e2e.secrets!.required = config.env!.e2e.secrets!.required!.filter((name) => name !== "TEST_AUTH_SECRET"); }, "E2E API required secret names"],
    ["sharing required secret", (_config: WranglerConfig, sharing: WranglerConfig) => { sharing.env!.e2e.secrets!.required = []; }, "E2E sharing required secret names"],
  ] as const)("rejects %s", (_name, mutateApi, expected) => {
    const api = apiConfig();
    const sharing = sharingConfig();
    mutateApi(api, sharing);
    expect(verify(api, sharing).errors.join("\n")).toContain(expected);
  });

  it("pins E2E IDs to the independently supplied approved inventory", () => {
    const api = apiConfig();
    const sharing = sharingConfig();
    const e2e = api.env!.e2e;
    const approvedResources = {
      d1DatabaseId: e2e.d1_databases![0].database_id,
      kvNamespaceIds: {
        RISHI_DESKTOP_STATE: e2e.kv_namespaces![0].id,
        RATE_LIMIT_KV: e2e.kv_namespaces![1].id,
      },
    };
    e2e.d1_databases![0].database_id = "22222222-3333-4444-8555-666666666666";
    e2e.kv_namespaces![0].id = "cccccccccccccccccccccccccccccccc";
    const result = verifyE2EEnvironment({
      ...writeFixture(api, sharing),
      approvedResources,
    });
    expect(result.errors.join("\n")).toContain("E2E API D1 database ID must match the approved E2E resource inventory");
    expect(result.errors.join("\n")).toContain("E2E API KV namespace ID RISHI_DESKTOP_STATE must match the approved E2E resource inventory");
  });

  it("loads an approved inventory from an injectable JSONC manifest path", () => {
    const api = apiConfig();
    const sharing = sharingConfig();
    const fixture = writeFixture(api, sharing);
    const manifestPath = join(dirname(fixture.apiConfigPath), "approved-resources.jsonc");
    const e2e = api.env!.e2e;
    writeFileSync(manifestPath, `// Cloudflare-emitted IDs\n${JSON.stringify({
      d1_database_id: e2e.d1_databases![0].database_id,
      kv_namespace_ids: {
        RISHI_DESKTOP_STATE: e2e.kv_namespaces![0].id,
        RATE_LIMIT_KV: e2e.kv_namespaces![1].id,
      },
    }, null, 2)}\n`);
    const result = verifyE2EEnvironment({ ...fixture, approvedResourcesPath: manifestPath });
    expect(result.errors).toEqual([]);
  });

  it("requires the separate approved inventory when no injectable input is supplied", () => {
    const result = verifyE2EEnvironment(writeFixture(apiConfig(), sharingConfig()));
    expect(result.errors).toContain("approved E2E resource manifest is required");
  });

  it("rejects a malformed JSONC document without echoing its contents", () => {
    const directory = mkdtempSync(join(tmpdir(), "rishi-e2e-verifier-"));
    temporaryDirectories.push(directory);
    const apiConfigPath = join(directory, "wrangler.jsonc");
    const sharingConfigPath = join(directory, "sharing-wrangler.jsonc");
    const secretValue = "never-print-this-secret";
    writeFileSync(apiConfigPath, `{ "vars": { "secret": "${secretValue}" },`);
    writeFileSync(sharingConfigPath, JSON.stringify(sharingConfig()));
    const output = verifyE2EEnvironment({ apiConfigPath, sharingConfigPath });
    expect(output.errors.join("\n")).not.toContain(secretValue);
    expect(output.errors.join("\n")).toContain("API config JSONC parse error");
  });

  it("parses comments and trailing commas from real JSONC-shaped input", () => {
    const fixture = verify();
    expect(fixture.errors).toEqual([]);
    const { apiConfigPath } = writeFixture(apiConfig(), sharingConfig());
    expect(readFileSync(apiConfigPath, "utf8")).toContain("// JSONC fixture");
  });
});
