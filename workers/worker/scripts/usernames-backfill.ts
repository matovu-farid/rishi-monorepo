#!/usr/bin/env bun

import { spawnSync } from "node:child_process";
import { generateUsernameCandidate } from "../src/usernames";

const WORKER_DIR = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const DEFAULT_BATCH_SIZE = 100;
const MAX_LIMIT = 10_000;
const MAX_ATTEMPTS = 8;

export interface Flags {
  dryRun: boolean;
  remote: boolean;
  limit?: number;
  help: boolean;
}

export function parseFlags(argv: string[]): Flags {
  const flags: Flags = {
    dryRun: false,
    remote: false,
    limit: undefined,
    help: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (argument === "--dry-run") flags.dryRun = true;
    else if (argument === "--remote") flags.remote = true;
    else if (argument === "--help" || argument === "-h") flags.help = true;
    else if (argument === "--limit") {
      const value = Number(argv[++index]);
      if (!Number.isInteger(value) || value <= 0) throw new Error("--limit requires a positive integer");
      flags.limit = Math.min(value, MAX_LIMIT);
    } else if (argument.startsWith("--limit=")) {
      const value = Number(argument.slice("--limit=".length));
      if (!Number.isInteger(value) || value <= 0) throw new Error("--limit requires a positive integer");
      flags.limit = Math.min(value, MAX_LIMIT);
    } else {
      throw new Error(`Unknown flag: ${argument}`);
    }
  }
  return flags;
}

function printHelp(): void {
  console.log(`
Usage: bun run scripts/usernames-backfill.ts [--dry-run] [--remote] [--limit N]

Allocates usernames for every user row missing a usernames row. The operation
is idempotent and uses the usernames unique index as its race authority.

  --dry-run   Report candidates without writing to D1.
  --remote    Target production D1. A five-second confirmation pause is used.
  --limit N   Process at most N users (cap ${MAX_LIMIT}); without it, process all users.
  --help      Show this message.

Production command:
  bun run scripts/usernames-backfill.ts --remote

Exit codes: 0 success, 1 when one or more users fail.
`);
}

function quote(value: string | number): string {
  return typeof value === "number" ? String(value) : `'${value.replace(/'/g, "''")}'`;
}

function execute(sql: string, remote: boolean): unknown[] {
  const args = [
    "wrangler", "d1", "execute", "rishi", remote ? "--remote" : "--local",
    "--command", sql, "--json",
  ];
  const result = spawnSync("bunx", args, {
    cwd: WORKER_DIR,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    throw new Error(`bunx wrangler d1 execute failed:\n${result.stderr}\n${result.stdout}`);
  }
  const parsed = JSON.parse(result.stdout) as unknown;
  if (Array.isArray(parsed)) return (parsed[0] as { results?: unknown[] } | undefined)?.results ?? [];
  return (parsed as { results?: unknown[] }).results ?? [];
}

type UserRow = { id: string; name: string };

function findUsers(limit: number, remote: boolean): UserRow[] {
  const rows = execute(
    `SELECT user.id, user.name FROM user LEFT JOIN usernames ON usernames.user_id = user.id WHERE usernames.user_id IS NULL ORDER BY user.id LIMIT ${quote(limit)};`,
    remote,
  );
  return rows.filter((row): row is UserRow =>
    typeof row === "object" && row !== null &&
    typeof (row as UserRow).id === "string" && typeof (row as UserRow).name === "string",
  );
}

function allocateOne(user: UserRow, remote: boolean): string {
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const candidate = generateUsernameCandidate(user.name);
    execute(
      `INSERT INTO usernames (user_id, username, created_at, updated_at) VALUES (${quote(user.id)}, ${quote(candidate)}, unixepoch() * 1000, unixepoch() * 1000) ON CONFLICT DO NOTHING;`,
      remote,
    );
    const rows = execute(
      `SELECT username FROM usernames WHERE user_id = ${quote(user.id)} LIMIT 1;`,
      remote,
    );
    const username = (rows[0] as { username?: unknown } | undefined)?.username;
    if (typeof username === "string") return username;
  }
  throw new Error("USERNAME_UNAVAILABLE after bounded retries");
}

async function main(): Promise<number> {
  let flags: Flags;
  try {
    flags = parseFlags(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
  if (flags.help) {
    printHelp();
    return 0;
  }
  if (flags.remote && !flags.dryRun) {
    console.warn("REMOTE MODE: this will write production D1. Continuing in 5 seconds; press Ctrl-C to abort.");
    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }

  let failures = 0;
  let processed = 0;
  let totalFound = 0;
  const dryRunSnapshot = flags.dryRun && flags.limit === undefined;
  let dryRunTruncated = false;

  while (flags.limit === undefined || processed < flags.limit) {
    const batchLimit = dryRunSnapshot
      ? MAX_LIMIT
      : flags.limit === undefined
      ? DEFAULT_BATCH_SIZE
      : Math.min(DEFAULT_BATCH_SIZE, flags.limit - processed);
    if (batchLimit <= 0) break;

    let users: UserRow[];
    try {
      users = findUsers(batchLimit, flags.remote);
    } catch (error) {
      console.error(`Backfill preflight failed: ${error instanceof Error ? error.message : String(error)}`);
      return 1;
    }
    if (users.length === 0) break;
    totalFound += users.length;
    if (dryRunSnapshot && users.length === MAX_LIMIT) dryRunTruncated = true;
    console.log(`Found ${users.length} user(s) in this batch.`);

    for (const user of users) {
      try {
        if (flags.dryRun) {
          console.log(`[dry-run] ${user.id} (${user.name}) → ${generateUsernameCandidate(user.name)}`);
        } else {
          console.log(`[ok] ${user.id} → ${allocateOne(user, flags.remote)}`);
        }
        processed += 1;
      } catch (error) {
        failures += 1;
        console.error(`[fail] ${user.id}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    // A failed row remains eligible on the next query. Stop rather than
    // repeatedly retrying it forever; the non-zero exit tells the operator
    // that the backfill is incomplete.
    if (failures > 0) break;
    if (dryRunSnapshot) break;
  }

  if (dryRunSnapshot) {
    if (dryRunTruncated) {
      console.warn(`Dry-run snapshot capped at ${MAX_LIMIT} users; rerun with --limit or after the migration is reconciled.`);
      return 1;
    }
  }

  if (flags.limit !== undefined && processed >= flags.limit) {
    try {
      if (findUsers(1, flags.remote).length > 0) {
        console.warn(`Limit reached after ${processed} user(s); rerun without --limit to finish the backfill.`);
        return 1;
      }
    } catch (error) {
      console.error(`Backfill completion check failed: ${error instanceof Error ? error.message : String(error)}`);
      return 1;
    }
  }
  console.log(`Processed ${totalFound} user(s) missing usernames.`);
  return failures === 0 ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
