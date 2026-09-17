#!/usr/bin/env bun

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const workerDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const migrationsDirectory = resolve(workerDirectory, "drizzle/migrations");
const journalPath = "meta/_journal.json";

const appliedHistoricalMigrations = new Set([
  "20260820112725_session_invites_from_prod_session_only/migration.sql",
  "20260820121338_session_invites_idempotency/migration.sql",
]);

const appliedHistoricalArtifactHashes = new Map<string, string>([
  ["20260820112725_session_invites_from_prod_session_only/migration.sql", "19d6201be949a9b6811c2f629bfe96ddb0c264b29f4cbcd970a526658d5c7bb0"],
  ["20260820112725_session_invites_from_prod_session_only/snapshot.json", "ae26961a3032d04b1a18468c1cda2ad20d26cab3507814556360904dcada4a6a"],
  ["20260820121338_session_invites_idempotency/migration.sql", "c5b91174c89eb0fad4aa837935574d59be3e84e3bb7b259d421ae93b0c6535ac"],
  ["20260820121338_session_invites_idempotency/snapshot.json", "05cc2d7f25b554238f5231d83139bbf4ffb671ccbb52b7919c9224950be81212"],
] as const);

const knownExcludedReplacementMigrations = new Set([
  "20260713060447_superb_starjammers/migration.sql",
  "20260801174843_entitlement_retention/migration.sql",
]);

type Artifact = { path: string; sha256: string };

type MigrationSnapshot = {
  version: 1;
  migrationsPattern: string;
  activeNestedMigrations: string[];
  canonicalArtifacts: Artifact[];
  historicalEvidence: Artifact[];
  journalSha256: string;
};

function digest(contents: string): string {
  return createHash("sha256").update(contents).digest("hex");
}

function readMigrationPattern(): string {
  const config = readFileSync(resolve(workerDirectory, "wrangler.jsonc"), "utf8");
  const pattern = config.match(/"migrations_pattern"\s*:\s*"([^"]+)"/)?.[1];
  if (!pattern) throw new Error("wrangler.jsonc must define one explicit migrations_pattern");
  if (!pattern.startsWith("drizzle/migrations/{") || !pattern.endsWith("}")) {
    throw new Error("migrations_pattern must use an explicit drizzle/migrations allowlist");
  }
  return pattern;
}

function configuredNestedMigrations(pattern: string): string[] {
  const entries = pattern.slice("drizzle/migrations/{".length, -1).split(",");
  if (!entries.includes("*.sql")) throw new Error("migrations_pattern must retain the top-level SQL allowlist");
  const nested = entries.filter((entry) => entry.endsWith("/migration.sql"));
  if (nested.length === 0) throw new Error("wrangler.jsonc must explicitly allowlist active nested Drizzle migrations");
  if (new Set(nested).size !== nested.length) throw new Error("migrations_pattern contains a duplicate nested migration");
  if (nested.some((entry) => entry.includes("*") || entry.includes("reconciliation/"))) {
    throw new Error("migrations_pattern must not glob or deploy reconciliation migrations");
  }
  return nested;
}

function nestedMigrationFiles(): string[] {
  return readdirSync(migrationsDirectory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => `${entry.name}/migration.sql`)
    .filter((path) => {
      try {
        readFileSync(resolve(migrationsDirectory, path), "utf8");
        return true;
      } catch {
        return false;
      }
    })
    .sort((left, right) => left.localeCompare(right, undefined, { numeric: true }));
}

function assertActiveMigrationAllowlist(configured: string[]): void {
  const active = nestedMigrationFiles().filter((path) =>
    !knownExcludedReplacementMigrations.has(path),
  );
  if (configured.join("\0") !== active.join("\0")) {
    throw new Error([
      "wrangler.jsonc nested migration allowlist does not exactly match the active canonical chain.",
      `Configured: ${configured.join(", ")}`,
      `Expected: ${active.join(", ")}`,
    ].join("\n"));
  }
  for (const migration of configured) {
    const snapshot = migration.replace(/\/migration\.sql$/, "/snapshot.json");
    try {
      readFileSync(resolve(migrationsDirectory, migration), "utf8");
      readFileSync(resolve(migrationsDirectory, snapshot), "utf8");
    } catch {
      throw new Error(`Configured migration must retain generated SQL and snapshot: ${migration}`);
    }
  }
  for (const migration of appliedHistoricalMigrations) {
    const snapshot = migration.replace(/\/migration\.sql$/, "/snapshot.json");
    for (const path of [migration, snapshot]) {
      let contents: string;
      try {
        contents = readFileSync(resolve(migrationsDirectory, path), "utf8");
      } catch {
        throw new Error(`Applied historical migration evidence is missing: ${path}`);
      }
        const actual = digest(contents);
        const expected = appliedHistoricalArtifactHashes.get(path);
        if (!expected || actual !== expected) {
          throw new Error(`Applied historical migration hash changed: ${path}`);
        }
    }
  }
}

function collectArtifacts(directory = migrationsDirectory, prefix = ""): Artifact[] {
  const artifacts: Artifact[] = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === "reconciliation") throw new Error("reconciliation output must not exist in the deployable migration directory");
    const path = prefix ? `${prefix}/${entry.name}` : entry.name;
    const absolute = resolve(directory, entry.name);
    if (entry.isDirectory()) artifacts.push(...collectArtifacts(absolute, path));
    else if (entry.isFile()) artifacts.push({ path, sha256: digest(readFileSync(absolute, "utf8")) });
    else throw new Error(`unsupported migration artifact: ${path}`);
  }
  return artifacts.sort((left, right) => left.path.localeCompare(right.path));
}

function collectSnapshot(): MigrationSnapshot {
  const migrationsPattern = readMigrationPattern();
  const activeNestedMigrations = configuredNestedMigrations(migrationsPattern);
  assertActiveMigrationAllowlist(activeNestedMigrations);
  const historicalPaths = new Set([
    ...appliedHistoricalMigrations,
    ...[...appliedHistoricalMigrations].map((path) => path.replace(/\/migration\.sql$/, "/snapshot.json")),
  ]);
  const artifacts = collectArtifacts();
  const historicalEvidence = artifacts.filter((artifact) => historicalPaths.has(artifact.path));
  const canonicalArtifacts = artifacts.filter((artifact) => !historicalPaths.has(artifact.path));
  const journal = canonicalArtifacts.find((artifact) => artifact.path === journalPath);
  if (!journal) throw new Error("canonical migration journal is missing");
  return { version: 1, migrationsPattern, activeNestedMigrations, canonicalArtifacts, historicalEvidence, journalSha256: journal.sha256 };
}

function sameArtifacts(left: Artifact[], right: Artifact[]): boolean {
  return left.length === right.length && left.every((artifact, index) =>
    artifact.path === right[index]?.path && artifact.sha256 === right[index]?.sha256,
  );
}

function parseBefore(path: string): MigrationSnapshot {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new Error("before-state is missing or malformed");
  }
  const value = parsed as Partial<MigrationSnapshot>;
  const validArtifacts = (artifacts: unknown): artifacts is Artifact[] => Array.isArray(artifacts)
    && artifacts.every((artifact) => Boolean(artifact) && typeof artifact === "object"
      && typeof (artifact as Artifact).path === "string" && /^[a-f0-9]{64}$/.test((artifact as Artifact).sha256));
  if (value.version !== 1 || typeof value.migrationsPattern !== "string"
    || !Array.isArray(value.activeNestedMigrations) || !value.activeNestedMigrations.every((migration) => typeof migration === "string")
    || !validArtifacts(value.canonicalArtifacts) || !validArtifacts(value.historicalEvidence)
    || typeof value.journalSha256 !== "string" || !/^[a-f0-9]{64}$/.test(value.journalSha256)) {
    throw new Error("before-state is malformed");
  }
  return value as MigrationSnapshot;
}

function executableStatements(sql: string): string[] {
  return sql.split("--> statement-breakpoint")
    .map((statement) => statement.replace(/^\s*--.*$/gm, "").trim())
    .filter(Boolean);
}

function assertNoop(before: MigrationSnapshot, current: MigrationSnapshot, generatedName: string, expectedStatements: number): void {
  if (!/^[a-z0-9_]+$/.test(generatedName)) throw new Error("generated migration name is malformed");
  if (expectedStatements !== 0) throw new Error("canonical no-op verification only accepts zero executable statements");
  if (before.migrationsPattern !== current.migrationsPattern
    || before.activeNestedMigrations.join("\0") !== current.activeNestedMigrations.join("\0")
    || !sameArtifacts(before.historicalEvidence, current.historicalEvidence)) {
    throw new Error("migration pattern or applied historical evidence changed during no-op generation");
  }
  if (before.journalSha256 !== current.journalSha256) throw new Error("Drizzle migration journal changed during canonical no-op generation");
  const beforeByPath = new Map(before.canonicalArtifacts.map((artifact) => [artifact.path, artifact]));
  const additions = current.canonicalArtifacts.filter((artifact) => !beforeByPath.has(artifact.path));
  const changed = current.canonicalArtifacts.filter((artifact) => {
    const earlier = beforeByPath.get(artifact.path);
    return earlier && earlier.sha256 !== artifact.sha256;
  });
  const removals = before.canonicalArtifacts.filter((artifact) => !current.canonicalArtifacts.some((candidate) => candidate.path === artifact.path));
  if (changed.length > 0 || removals.length > 0) throw new Error("canonical migration artifacts changed during no-op generation");
  if (additions.length === 0) return;
  const expectedPaths = [`${generatedName}/migration.sql`, `${generatedName}/snapshot.json`];
  if (additions.length !== expectedPaths.length || !expectedPaths.every((path) => additions.some((artifact) => artifact.path === path))) {
    throw new Error("canonical no-op generation added unexpected artifacts");
  }
  const migration = additions.find((artifact) => artifact.path === `${generatedName}/migration.sql`)!;
  const statements = executableStatements(readFileSync(resolve(migrationsDirectory, migration.path), "utf8"));
  if (statements.length !== expectedStatements) throw new Error(`generated migration has ${statements.length} executable statements; expected ${expectedStatements}`);
  if (statements.some((statement) => /\b(?:ALTER|CREATE|DELETE|DROP|INSERT|PRAGMA|REPLACE|UPDATE|VACUUM)\b/i.test(statement))) {
    throw new Error("generated no-op migration contains DDL or DML");
  }
}

function takeOption(arguments_: string[], name: string): string {
  const index = arguments_.indexOf(name);
  const value = arguments_[index + 1];
  if (index < 0 || !value || value.startsWith("--")) throw new Error(`${name} requires a value`);
  return value;
}

function main(arguments_: string[]): void {
  if (arguments_.length === 0) {
    const snapshot = collectSnapshot();
    console.log(`Migration pattern verified: ${snapshot.activeNestedMigrations.join(", ")}`);
    return;
  }
  if (arguments_[0] === "--snapshot-before" && arguments_.length === 2) {
    writeFileSync(takeOption(arguments_, "--snapshot-before"), `${JSON.stringify(collectSnapshot(), null, 2)}\n`);
    return;
  }
  if (arguments_[0] === "--assert-noop" && arguments_.length === 7) {
    const before = parseBefore(takeOption(arguments_, "--before"));
    const generatedName = takeOption(arguments_, "--generated-name");
    const expectedStatements = Number(takeOption(arguments_, "--expect-executable-statements"));
    if (!Number.isInteger(expectedStatements) || expectedStatements < 0) throw new Error("--expect-executable-statements must be a non-negative integer");
    assertNoop(before, collectSnapshot(), generatedName, expectedStatements);
    return;
  }
  throw new Error("usage: verify-migration-pattern.ts [--snapshot-before PATH | --assert-noop --before PATH --generated-name NAME --expect-executable-statements 0]");
}

main(process.argv.slice(2));
