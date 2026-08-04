#!/usr/bin/env bun

import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const workerDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const migrationsDirectory = resolve(workerDirectory, "drizzle/migrations");
const config = readFileSync(resolve(workerDirectory, "wrangler.jsonc"), "utf8");

const configuredNested = config.match(/migrations_pattern"\s*:\s*"[^"]*?,([^/]+\/migration\.sql)/)?.[1];
if (!configuredNested) {
  throw new Error("wrangler.jsonc must explicitly allowlist the active nested Drizzle migration");
}

try {
  readFileSync(resolve(migrationsDirectory, configuredNested), "utf8");
} catch {
  throw new Error(`Configured nested migration does not exist: ${configuredNested}`);
}

const knownExcludedReplacementMigrations = new Set([
  "20260713060447_superb_starjammers/migration.sql",
  "20260801174843_entitlement_retention/migration.sql",
]);

const nestedMigrations = readdirSync(migrationsDirectory, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => `${entry.name}/migration.sql`)
  .filter((name) => {
    try {
      readFileSync(resolve(migrationsDirectory, name), "utf8");
      return true;
    } catch {
      return false;
    }
  });

const unknownNestedMigrations = nestedMigrations.filter((name) =>
  name !== configuredNested && !knownExcludedReplacementMigrations.has(name),
);

if (unknownNestedMigrations.length > 0) {
  throw new Error([
    "New nested Drizzle migration(s) are not covered by wrangler.jsonc:",
    ...unknownNestedMigrations.map((name) => `  - ${name}`),
    `Update migrations_pattern only after checking remote d1_migrations; do not broaden it blindly.`,
  ].join("\n"));
}

console.log(`Migration pattern verified: ${configuredNested}`);
