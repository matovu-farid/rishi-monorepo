#!/usr/bin/env bun

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse, printParseErrorCode, type ParseError } from "jsonc-parser";

export type JsonObject = Record<string, any>;

export interface WranglerConfig extends JsonObject {
  name?: string;
  compatibility_date?: string;
  compatibility_flags?: string[];
  version_metadata?: JsonObject;
  services?: JsonObject[];
  d1_databases?: JsonObject[];
  r2_buckets?: JsonObject[];
  kv_namespaces?: JsonObject[];
  durable_objects?: JsonObject;
  migrations?: JsonObject[];
  rules?: JsonObject[];
  vars: Record<string, any>;
  secrets?: { required?: string[] };
  routes?: JsonObject[];
  triggers?: JsonObject;
  observability?: JsonObject;
  env?: Record<string, WranglerConfig>;
}

export interface E2EConfigPaths {
  apiConfigPath: string;
  sharingConfigPath: string;
  approvedResourcesPath?: string;
  approvedResources?: ApprovedResourceInventory;
}

export interface ApprovedResourceInventory {
  d1DatabaseId: string;
  kvNamespaceIds: {
    RISHI_DESKTOP_STATE: string;
    RATE_LIMIT_KV: string;
  };
}

export interface E2EVerificationResult {
  errors: string[];
  summary: string;
}

const ACCOUNT_ID = "b700cf80e995aacbfa27aaa8d2084d18";
const PRODUCTION_API_NAME = "rishi-worker";
const E2E_API_NAME = "rishi-worker-e2e";
const PRODUCTION_SHARING_NAME = "rishi-sharing-worker";
const E2E_SHARING_NAME = "rishi-sharing-worker-e2e";
const PRODUCTION_D1_NAME = "rishi";
const E2E_D1_NAME = "rishi-e2e";
const PRODUCTION_D1_ID = "970159b7-ca91-49c1-bae8-feb43b24a7e6";
const PRODUCTION_KV_IDS = {
  RISHI_DESKTOP_STATE: "12eb084c99f44bebafcf1143bc457f58",
  RATE_LIMIT_KV: "34c4751c01a94f22a04a211f4eec8d54",
} as const;
const PRODUCTION_KV_PREVIEW_IDS = {
  RISHI_DESKTOP_STATE: "49a43a76aac747ad8472856f33e1eeda",
  RATE_LIMIT_KV: "76cdf05f101043a892c02ce590e4a694",
} as const;
const PRODUCTION_BUCKETS = {
  APPLE: "apple",
  BOOK_STORAGE: "rishi-books",
  TTS_CACHE: "rishi-tts-cache",
  apple_dev: "apple-dev",
} as const;
const E2E_BUCKETS = {
  APPLE: "apple-e2e",
  BOOK_STORAGE: "rishi-books-e2e",
  TTS_CACHE: "rishi-tts-cache-e2e",
  apple_dev: "apple-dev-e2e",
} as const;
const COMPATIBILITY = {
  apiDate: "2025-11-17",
  apiFlags: ["nodejs_als", "nodejs_compat"],
  sharingDate: "2026-05-30",
  sharingFlags: ["nodejs_compat"],
} as const;
const MIGRATIONS_PATTERN =
  "drizzle/migrations/{*.sql,20260803145911_classy_sleepwalker/migration.sql,20260808181936_book_sharing/migration.sql,20260812135706_book_sharing_access/migration.sql,20260813110000_pregenerated_share_links/migration.sql,20260820112725_session_invites_from_prod_session_only/migration.sql,20260820121338_session_invites_idempotency/migration.sql}";
const PRODUCTION_CRONS = ["17 2 * * *", "* * * * *"];
const API_E2E_SECRETS = [
  "TEST_AUTH_SECRET",
  "BETTER_AUTH_SECRET",
  "SHARING_INTERNAL_SECRET",
  "ACCESS_TOKEN_SECRET",
  "REFRESH_TOKEN_SECRET",
  "VOICE_SESSION_NONCE_SECRET",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
];
const PRODUCTION_API_SECRETS = [
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

function readJsoncConfig(path: string, label: string): WranglerConfig {
  let source: string;
  try {
    source = readFileSync(path, "utf8");
  } catch {
    throw new Error(`${label} config could not be read`);
  }
  const parseErrors: ParseError[] = [];
  const value = parse(source, parseErrors, { allowTrailingComma: true, disallowComments: false });
  if (parseErrors.length > 0) {
    const code = printParseErrorCode(parseErrors[0].error);
    throw new Error(`${label} config JSONC parse error: ${code}`);
  }
  if (!isRecord(value)) throw new Error(`${label} config JSONC root must be an object`);
  return value as WranglerConfig;
}

function readApprovedResources(paths: E2EConfigPaths, errors: string[]): ApprovedResourceInventory | undefined {
  if (paths.approvedResources) return normalizeApprovedResources(paths.approvedResources, errors);
  if (!paths.approvedResourcesPath) {
    errors.push("approved E2E resource manifest is required");
    return undefined;
  }
  let source: string;
  try {
    source = readFileSync(paths.approvedResourcesPath, "utf8");
  } catch {
    errors.push("approved E2E resource manifest is missing");
    return undefined;
  }
  const parseErrors: ParseError[] = [];
  const value = parse(source, parseErrors, { allowTrailingComma: true, disallowComments: false });
  if (parseErrors.length > 0) {
    errors.push(`approved E2E resource manifest JSONC parse error: ${printParseErrorCode(parseErrors[0].error)}`);
    return undefined;
  }
  if (!isRecord(value)) {
    errors.push("approved E2E resource manifest must be an object");
    return undefined;
  }
  return normalizeApprovedResources({
    d1DatabaseId: value.d1_database_id,
    kvNamespaceIds: isRecord(value.kv_namespace_ids) ? {
      RISHI_DESKTOP_STATE: value.kv_namespace_ids.RISHI_DESKTOP_STATE,
      RATE_LIMIT_KV: value.kv_namespace_ids.RATE_LIMIT_KV,
    } : undefined,
  }, errors);
}

function isRecord(value: unknown): value is JsonObject {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function normalizeApprovedResources(value: unknown, errors: string[]): ApprovedResourceInventory | undefined {
  if (!isRecord(value) || typeof value.d1DatabaseId !== "string" || !isRecord(value.kvNamespaceIds)
    || typeof value.kvNamespaceIds.RISHI_DESKTOP_STATE !== "string"
    || typeof value.kvNamespaceIds.RATE_LIMIT_KV !== "string") {
    errors.push("approved E2E resource manifest must contain d1_database_id and both kv_namespace_ids");
    return undefined;
  }
  const d1DatabaseId = value.d1DatabaseId;
  const kvNamespaceIds = {
    RISHI_DESKTOP_STATE: value.kvNamespaceIds.RISHI_DESKTOP_STATE,
    RATE_LIMIT_KV: value.kvNamespaceIds.RATE_LIMIT_KV,
  };
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(d1DatabaseId)) {
    errors.push("approved E2E D1 database ID is malformed");
  }
  if (Object.values(kvNamespaceIds).some((id) => !/^[a-f0-9]{32}$/.test(id))) {
    errors.push("approved E2E KV namespace ID is malformed");
  }
  if (d1DatabaseId === PRODUCTION_D1_ID) errors.push("approved E2E D1 database ID must not be production");
  const productionKvIds = new Set<string>([
    ...Object.values(PRODUCTION_KV_IDS),
    ...Object.values(PRODUCTION_KV_PREVIEW_IDS),
  ]);
  if (Object.values(kvNamespaceIds).some((id) => productionKvIds.has(id))) {
    errors.push("approved E2E KV namespace IDs must not be production IDs or production preview IDs");
  }
  if (new Set(Object.values(kvNamespaceIds)).size !== 2) errors.push("approved E2E KV namespace IDs must be distinct");
  return { d1DatabaseId, kvNamespaceIds };
}

function equal(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function sortedNames(value: unknown): string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string")
    ? [...value].sort()
    : [];
}

function namedEntries(value: unknown, key: string): Map<string, JsonObject> {
  const result = new Map<string, JsonObject>();
  if (!Array.isArray(value)) return result;
  for (const entry of value) {
    if (isRecord(entry) && typeof entry[key] === "string") result.set(entry[key], entry);
  }
  return result;
}

function rawBindingEntries(
  value: unknown,
  kind: "R2" | "KV",
  expectedLength: number,
  label: string,
  errors: string[],
): JsonObject[] {
  if (!Array.isArray(value)) {
    errors.push(`${label} ${kind} binding array is required`);
    return [];
  }
  if (value.length !== expectedLength) {
    errors.push(`${label} ${kind} binding array must contain exactly ${expectedLength} entries`);
  }
  const entries = value.filter(isRecord);
  if (entries.length !== value.length) errors.push(`${label} ${kind} binding entries must be objects`);
  const names = entries.map((entry) => entry.binding).filter((binding): binding is string => typeof binding === "string");
  if (new Set(names).size !== names.length) errors.push(`${label} ${kind} binding names must be unique`);
  if (names.length !== entries.length) errors.push(`${label} ${kind} binding names are required`);
  return entries;
}

function exactNames(actual: unknown, expected: string[]): boolean {
  return equal(sortedNames(actual), [...expected].sort());
}

function requireExact(
  errors: string[],
  actual: unknown,
  expected: unknown,
  message: string,
): void {
  if (!equal(actual, expected)) errors.push(message);
}

function requireOwn(config: WranglerConfig, property: string, message: string, errors: string[]): void {
  if (!Object.prototype.hasOwnProperty.call(config, property)) errors.push(message);
}

function validateCompatibility(
  config: WranglerConfig,
  date: string,
  flags: readonly string[],
  label: string,
  errors: string[],
): void {
  if (config.compatibility_date !== date) errors.push(`${label} compatibility date must remain ${date}`);
  if (!equal(config.compatibility_flags, flags)) errors.push(`${label} compatibility flags must remain ${flags.join(", ")}`);
}

function validateRoutes(config: WranglerConfig, pattern: string, label: string, errors: string[]): void {
  if (!equal(config.routes, [{ pattern, custom_domain: true }])) {
    errors.push(`${label} custom domain must be exactly ${pattern}`);
  }
}

function validateD1(
  config: WranglerConfig,
  expectedName: string,
  expectedId: string | undefined,
  label: string,
  errors: string[],
): void {
  const entries = config.d1_databases;
  if (!Array.isArray(entries) || entries.length !== 1 || !isRecord(entries[0])) {
    errors.push(`${label} D1 binding must declare exactly one database`);
    return;
  }
  const database = entries[0];
  if (database.binding !== "DB") errors.push(`${label} D1 binding must be DB`);
  if (database.database_name !== expectedName) errors.push(`${label} D1 database name must be ${expectedName}`);
  if (typeof database.database_id !== "string" || database.database_id.length === 0) {
    errors.push(`${label} D1 database ID is required`);
  } else if (expectedId && database.database_id !== expectedId) {
    errors.push(`${label} D1 database ID must ${expectedName === E2E_D1_NAME ? "match the approved E2E resource inventory" : "remain the production ID"}`);
  } else if (!expectedId && database.database_id === PRODUCTION_D1_ID) {
    errors.push(`${label} D1 database ID must be E2E-only`);
  }
  if (database.migrations_dir !== "drizzle/migrations") errors.push(`${label} D1 migrations directory must be drizzle/migrations`);
  if (database.migrations_pattern !== MIGRATIONS_PATTERN) errors.push(`${label} D1 migrations pattern must remain explicit`);
}

function validateBuckets(
  config: WranglerConfig,
  expected: Record<string, string>,
  label: string,
  errors: string[],
): Map<string, JsonObject> {
  const rawEntries = rawBindingEntries(config.r2_buckets, "R2", Object.keys(expected).length, label, errors);
  const entries = new Map(rawEntries.map((entry) => [entry.binding as string, entry]));
  if (entries.size !== Object.keys(expected).length) errors.push(`${label} R2 bindings must be complete and contain no extras`);
  for (const [binding, bucketName] of Object.entries(expected)) {
    const entry = entries.get(binding);
    if (!entry) errors.push(`${label} R2 binding ${binding} is required`);
    else if (entry.bucket_name !== bucketName) errors.push(`${label} R2 bucket ${binding} must be ${bucketName}`);
  }
  return entries;
}

function validateKv(
  config: WranglerConfig,
  expected: Record<string, string> | undefined,
  label: string,
  errors: string[],
  mode: "production" | "e2e",
): Map<string, JsonObject> {
  const rawEntries = rawBindingEntries(config.kv_namespaces, "KV", 2, label, errors);
  const entries = new Map(rawEntries.map((entry) => [entry.binding as string, entry]));
  if (entries.size !== 2) errors.push(`${label} KV bindings must contain exactly two namespaces`);
  const ids = [...entries.values()].map((entry) => entry.id).filter((id): id is string => typeof id === "string");
  if (new Set(ids).size !== ids.length) errors.push(`${label} KV namespace IDs must be distinct`);
  for (const binding of ["RISHI_DESKTOP_STATE", "RATE_LIMIT_KV"]) {
    const entry = entries.get(binding);
    if (!entry) {
      errors.push(`${label} KV binding ${binding} is required`);
      continue;
    }
    if (typeof entry.id !== "string" || !/^[a-f0-9]{32}$/.test(entry.id)) errors.push(`${label} KV namespace ID ${binding} is malformed`);
    if (mode === "production" && expected && entry.id !== expected[binding]) errors.push(`${label} KV namespace ID ${binding} must remain the production ID`);
    if (mode === "e2e" && expected && entry.id !== expected[binding]) errors.push(`${label} KV namespace ID ${binding} must match the approved E2E resource inventory`);
    if (mode === "e2e" && (entry.id === PRODUCTION_KV_IDS.RISHI_DESKTOP_STATE
      || entry.id === PRODUCTION_KV_IDS.RATE_LIMIT_KV)) {
      errors.push(`${label} KV namespace ID ${binding} must not match a production ID`);
    }
    if (mode === "e2e" && (entry.id === PRODUCTION_KV_PREVIEW_IDS.RISHI_DESKTOP_STATE
      || entry.id === PRODUCTION_KV_PREVIEW_IDS.RATE_LIMIT_KV)) {
      errors.push(`${label} KV namespace ID ${binding} must not match a production preview ID`);
    }
    if (mode === "production" && expected && entry.preview_id !== PRODUCTION_KV_PREVIEW_IDS[binding as keyof typeof PRODUCTION_KV_PREVIEW_IDS]) {
      errors.push(`${label} KV preview ID ${binding} must remain the production preview ID`);
    }
    if (mode === "e2e" && Object.prototype.hasOwnProperty.call(entry, "preview_id")) errors.push(`${label} KV namespace ${binding} must not declare a preview ID`);
  }
  return entries;
}

function validateDurableObjects(
  config: WranglerConfig,
  expectedBindings: unknown,
  expectedMigrations: unknown,
  label: string,
  errors: string[],
): void {
  requireExact(errors, config.durable_objects, expectedBindings, `${label} Durable Object bindings are incomplete or changed`);
  requireExact(errors, config.migrations, expectedMigrations, `${label} Durable Object migrations are incomplete or changed`);
}

const API_DO_MIGRATIONS = [{ tag: "v1", new_sqlite_classes: ["UserUsageLedger"] }];
const SHARING_DO_MIGRATIONS = [
  { tag: "v1", new_sqlite_classes: ["SessionRoom"] },
  { tag: "v2", new_sqlite_classes: ["AppleSessionRoom"] },
];
const API_DO_BINDINGS = { bindings: [{ name: "USER_USAGE_LEDGER", class_name: "UserUsageLedger" }] };
const SHARING_DO_BINDINGS = {
  bindings: [
    { name: "SESSION_ROOM", class_name: "SessionRoom" },
    { name: "APPLE_SESSION_ROOM", class_name: "AppleSessionRoom" },
  ],
};
const API_SQL_RULES = [{ type: "Text", globs: ["**/*.sql"], fallthrough: true }];
const API_VARS = {
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  SHARING_WORKER_WS_URL: "wss://sharing.fidexa.org",
  BOOK_STORAGE_BUCKET_NAME: "rishi-books",
  BOOK_MAX_FILE_BYTES: "838860800",
  BOOK_MAX_PER_USER: "500",
  BOOK_MAX_USER_BYTES: "10737418240",
};
const API_E2E_VARS = {
  PUBLIC_API_URL: "https://api-e2e.fidexa.org",
  PUBLIC_WEB_URL: "https://api-e2e.fidexa.org",
  SHARING_WORKER_WS_URL: "wss://sharing-e2e.fidexa.org",
  ENABLE_TEST_AUTH: "true",
  CLOUDFLARE_ACCOUNT_ID: ACCOUNT_ID,
  BOOK_STORAGE_BUCKET_NAME: "rishi-books-e2e",
  BOOK_MAX_FILE_BYTES: "838860800",
  BOOK_MAX_PER_USER: "500",
  BOOK_MAX_USER_BYTES: "10737418240",
};

function validateVars(
  actual: unknown,
  expected: Record<string, string>,
  label: string,
  errors: string[],
): void {
  if (!isRecord(actual)) {
    errors.push(`${label} vars are required`);
    return;
  }
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = Object.keys(expected).sort();
  if (!equal(actualKeys, expectedKeys)) errors.push(`${label} vars contain unexpected or missing keys`);
  for (const [key, value] of Object.entries(expected)) {
    if (!Object.prototype.hasOwnProperty.call(actual, key)) errors.push(`${label} ${key} is required`);
    else if (actual[key] !== value) errors.push(`${label} ${key} must be the approved value`);
  }
}

function validateApi(api: WranglerConfig, errors: string[]): void {
  if (api.name !== PRODUCTION_API_NAME) errors.push(`production API Worker name must be ${PRODUCTION_API_NAME}`);
  validateCompatibility(api, COMPATIBILITY.apiDate, COMPATIBILITY.apiFlags, "API", errors);
  requireExact(errors, api.version_metadata, { binding: "CF_VERSION_METADATA" }, "production API CF_VERSION_METADATA binding is required");
  requireExact(errors, api.services, [{ binding: "SHARING_WORKER", service: "rishi-sharing-worker" }], "production API service target must be rishi-sharing-worker");
  validateD1(api, PRODUCTION_D1_NAME, PRODUCTION_D1_ID, "production API", errors);
  validateBuckets(api, PRODUCTION_BUCKETS, "production API", errors);
  validateKv(api, PRODUCTION_KV_IDS, "production API", errors, "production");
  validateDurableObjects(api, API_DO_BINDINGS, API_DO_MIGRATIONS, "production API", errors);
  requireExact(errors, api.rules, API_SQL_RULES, "production API SQL text rule is required");
  validateVars(api.vars, API_VARS, "production API", errors);
  if (Object.prototype.hasOwnProperty.call(api.vars, "ENABLE_TEST_AUTH")) errors.push("production API must not enable test auth");
  if (Object.prototype.hasOwnProperty.call(api.vars, "TEST_AUTH_ALLOWED")) errors.push("production API must not enable sharing test auth");
  requireExact(errors, api.secrets?.required, PRODUCTION_API_SECRETS, "production API required secret names changed");
  requireExact(errors, api.triggers?.crons, PRODUCTION_CRONS, "production API cron schedule changed");
  validateRoutes(api, "api.fidexa.org", "production API", errors);
}

function validateApiE2E(
  api: WranglerConfig,
  productionApi: WranglerConfig,
  approvedResources: ApprovedResourceInventory | undefined,
  errors: string[],
): void {
  const e2e = api.env?.e2e;
  if (!e2e) {
    errors.push("API env.e2e block is missing");
    return;
  }
  if (e2e.name !== E2E_API_NAME) errors.push(`E2E API Worker name must be ${E2E_API_NAME}`);
  validateCompatibility(e2e, COMPATIBILITY.apiDate, COMPATIBILITY.apiFlags, "E2E API", errors);
  requireOwn(e2e, "version_metadata", "E2E API CF_VERSION_METADATA binding is required", errors);
  requireExact(errors, e2e.version_metadata, { binding: "CF_VERSION_METADATA" }, "E2E API CF_VERSION_METADATA binding is required");
  requireExact(errors, e2e.services, [{ binding: "SHARING_WORKER", service: E2E_SHARING_NAME }], "E2E API service target must be rishi-sharing-worker-e2e");
  validateD1(e2e, E2E_D1_NAME, approvedResources?.d1DatabaseId, "E2E API", errors);
  const database = e2e.d1_databases?.[0];
  if (database?.database_id === productionApi.d1_databases?.[0]?.database_id) errors.push("E2E API D1 database ID must differ from production");
  validateBuckets(e2e, E2E_BUCKETS, "E2E API", errors);
  validateKv(e2e, approvedResources?.kvNamespaceIds, "E2E API", errors, "e2e");
  validateDurableObjects(e2e, API_DO_BINDINGS, API_DO_MIGRATIONS, "E2E API", errors);
  requireExact(errors, e2e.rules, API_SQL_RULES, "E2E API SQL text rule is required");
  validateVars(e2e.vars, API_E2E_VARS, "E2E API", errors);
  requireExact(errors, e2e.secrets?.required, API_E2E_SECRETS, "E2E API required secret names are incomplete or changed");
  if (e2e.triggers?.crons && Array.isArray(e2e.triggers.crons) && e2e.triggers.crons.length > 0) errors.push("E2E API must not declare cron triggers");
  validateRoutes(e2e, "api-e2e.fidexa.org", "E2E API", errors);
  const productionBookBucket = namedEntries(productionApi.r2_buckets, "binding").get("BOOK_STORAGE")?.bucket_name;
  const e2eBookBucket = namedEntries(e2e.r2_buckets, "binding").get("BOOK_STORAGE")?.bucket_name;
  if (productionApi.vars.BOOK_STORAGE_BUCKET_NAME !== productionBookBucket) errors.push("production BOOK_STORAGE_BUCKET_NAME must equal the BOOK_STORAGE bucket_name");
  if (e2e.vars.BOOK_STORAGE_BUCKET_NAME !== e2eBookBucket) errors.push("E2E BOOK_STORAGE_BUCKET_NAME must equal the BOOK_STORAGE bucket_name");
}

function validateSharingProduction(config: WranglerConfig, errors: string[], complete = true): void {
  if (config.name !== PRODUCTION_SHARING_NAME) errors.push(`production sharing Worker name must be ${PRODUCTION_SHARING_NAME}`);
  if (complete || Object.prototype.hasOwnProperty.call(config, "compatibility_date")) {
    validateCompatibility(config, COMPATIBILITY.sharingDate, COMPATIBILITY.sharingFlags, "sharing", errors);
  }
  if (complete || Object.prototype.hasOwnProperty.call(config, "observability")) {
    requireExact(errors, config.observability, { enabled: true, head_sampling_rate: 1 }, "production sharing observability is required");
  }
  requireExact(errors, config.durable_objects, SHARING_DO_BINDINGS, "production sharing Durable Object bindings are incomplete or changed");
  requireExact(errors, config.migrations, SHARING_DO_MIGRATIONS, "production sharing Durable Object migrations are incomplete or changed");
  requireExact(errors, config.vars, { AUTH_BASE_URL: "https://api.fidexa.org" }, "production sharing AUTH_BASE_URL must remain production");
  validateRoutes(config, "sharing.fidexa.org", "production sharing", errors);
  if (config.services && config.services.length > 0) errors.push("production sharing Worker must not declare service bindings");
  if (Object.prototype.hasOwnProperty.call(config.vars, "TEST_AUTH_ALLOWED")) errors.push("production sharing must not enable test auth");
}

function validateSharing(config: WranglerConfig, errors: string[]): void {
  validateSharingProduction(config, errors);
  const production = config.env?.production;
  if (production) validateSharingProduction(production, errors, false);
  else errors.push("sharing production environment block is missing");
  const e2e = config.env?.e2e;
  if (!e2e) {
    errors.push("sharing env.e2e block is missing");
    return;
  }
  if (e2e.name !== E2E_SHARING_NAME) errors.push(`E2E sharing Worker name must be ${E2E_SHARING_NAME}`);
  validateCompatibility(e2e, COMPATIBILITY.sharingDate, COMPATIBILITY.sharingFlags, "E2E sharing", errors);
  requireExact(errors, e2e.observability, { enabled: true, head_sampling_rate: 1 }, "E2E sharing observability is required");
  requireExact(errors, e2e.durable_objects, SHARING_DO_BINDINGS, "E2E sharing Durable Object bindings are incomplete or changed");
  requireExact(errors, e2e.migrations, SHARING_DO_MIGRATIONS, "E2E sharing Durable Object migrations are incomplete or changed");
  validateVars(e2e.vars, { AUTH_BASE_URL: "https://api-e2e.fidexa.org", TEST_AUTH_ALLOWED: "1" }, "E2E sharing", errors);
  validateRoutes(e2e, "sharing-e2e.fidexa.org", "E2E sharing", errors);
  requireExact(errors, e2e.secrets?.required, ["WORKER_HMAC_SECRET"], "E2E sharing required secret names are incomplete or changed");
  if (e2e.services && e2e.services.length > 0) errors.push("E2E sharing Worker must not declare service bindings");
  if (e2e.triggers?.crons && Array.isArray(e2e.triggers.crons) && e2e.triggers.crons.length > 0) errors.push("E2E sharing must not declare cron triggers");
}

function summary(api: WranglerConfig, sharing: WranglerConfig): string {
  const apiE2E = api.env?.e2e;
  const sharingE2E = sharing.env?.e2e;
  const database = apiE2E?.d1_databases?.[0];
  const buckets = namedEntries(apiE2E?.r2_buckets, "binding");
  const bucketNames = ["APPLE", "BOOK_STORAGE", "TTS_CACHE", "apple_dev"]
    .map((binding) => buckets.get(binding)?.bucket_name)
    .filter((name): name is string => typeof name === "string")
    .join(",");
  return [
    `API=${apiE2E?.name ?? "missing"}`,
    `sharing=${sharingE2E?.name ?? "missing"}`,
    `D1=${database?.database_name ?? "missing"}`,
    `D1_ID=${database?.database_id ?? "missing"}`,
    `R2=${bucketNames || "missing"}`,
    `API_ORIGIN=${apiE2E?.vars?.PUBLIC_API_URL ?? "missing"}`,
    `SHARING_ORIGIN=${sharingE2E?.vars?.AUTH_BASE_URL ?? "missing"}`,
  ].join(" ");
}

export function verifyE2EEnvironment(paths: E2EConfigPaths): E2EVerificationResult {
  const errors: string[] = [];
  const approvedResources = readApprovedResources(paths, errors);
  let api: WranglerConfig | undefined;
  let sharing: WranglerConfig | undefined;
  try {
    api = readJsoncConfig(paths.apiConfigPath, "API");
  } catch (error) {
    errors.push(error instanceof Error ? error.message : "API config could not be read");
  }
  try {
    sharing = readJsoncConfig(paths.sharingConfigPath, "sharing");
  } catch (error) {
    errors.push(error instanceof Error ? error.message : "sharing config could not be read");
  }
  if (!api || !sharing) return { errors, summary: "" };
  validateApi(api, errors);
  validateApiE2E(api, api, approvedResources, errors);
  validateSharing(sharing, errors);
  return { errors, summary: summary(api, sharing) };
}

function argumentValue(arguments_: string[], names: string[], fallback: string): string {
  for (const name of names) {
    const index = arguments_.indexOf(name);
    if (index >= 0 && arguments_[index + 1] && !arguments_[index + 1].startsWith("--")) return arguments_[index + 1];
  }
  return fallback;
}

export function main(arguments_: string[] = process.argv.slice(2)): number {
  const workerDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const apiConfigPath = argumentValue(arguments_, ["--api-config", "--api"], resolve(workerDirectory, "wrangler.jsonc"));
  const sharingConfigPath = argumentValue(arguments_, ["--sharing-config", "--sharing"], resolve(workerDirectory, "..", "sharing-worker", "wrangler.jsonc"));
  const approvedResourcesPath = argumentValue(
    arguments_,
    ["--approved-manifest", "--approved-resources"],
    resolve(workerDirectory, "e2e-approved-resources.json"),
  );
  const result = verifyE2EEnvironment({ apiConfigPath, sharingConfigPath, approvedResourcesPath });
  if (result.errors.length > 0) {
    for (const error of result.errors) console.error(`E2E environment verification failed: ${error}`);
    return 1;
  }
  console.log(`E2E environment verified: ${result.summary}`);
  return 0;
}

if (import.meta.main) process.exit(main());
