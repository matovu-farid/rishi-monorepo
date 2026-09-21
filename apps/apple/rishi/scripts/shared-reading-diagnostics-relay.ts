#!/usr/bin/env bun

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";

const bundleID = "org.fidexa.rishi";
const actors = new Set(["owner-catalyst", "participant-iphone"]);
const events = new Set([
  "sharing.api.request",
  "sharing.api.response",
  "sharing.api.failure",
  "sharing.authentication.refresh",
  "sharing.local_book.validation",
  "sharing.socket",
  "sharing.reconnect",
  "sharing.signaling.event",
  "sharing.recovery",
  "sharing.registry",
  "sharing.session.lifecycle",
  "sharing.error.mapping",
]);
const levels = new Set(["debug", "info", "warning", "error", "fatal"]);
const fieldNames = new Set([
  "operation", "outcome", "correlation_id", "operation_id", "session_debug_id",
  "status_code", "duration_ms", "attempt", "room_epoch", "roster_generation",
  "controller_generation", "connection_generation", "sequence", "error_code",
  "event_timestamp", "relay_run_id", "actor", "actor_sequence",
]);

type RelayEvent = {
  event_timestamp: string;
  event: string;
  level: string;
  fields: Record<string, string>;
  actor: string;
  run_id: string;
  actor_sequence: number;
};

type StoredEvent = RelayEvent & {
  arrival_timestamp: string;
  arrival_sequence: number;
  source: "relay" | "fallback-import";
};

type Options = {
  output: string;
  iphoneUDID: string;
  catalystExecutable: string;
  catalystDump: string;
  iphoneActor: string;
  catalystActor: string;
};

function usage(): never {
  console.error(`Usage:
  bun apps/apple/rishi/scripts/shared-reading-diagnostics-relay.ts run \\
    --output <new-output-directory> \\
    --iphone-udid <simulator-udid> \\
    --catalyst-executable <built-catalyst-executable> \\
    --catalyst-dump <explicit-catalyst-rishi-dump-directory> \\
    [--iphone-actor participant-iphone] [--catalyst-actor owner-catalyst]

The command starts one loopback-only relay, launches the configured iPhone
Simulator and Catalyst apps with a fresh run configuration, and writes one
chronological shared-reading.ndjson file on Ctrl-C. It imports the two typed
local fallback outboxes once at shutdown; it never watches arbitrary logs.`);
  process.exit(64);
}

function parseOptions(args: string[]): Options {
  if (args.shift() !== "run") usage();
  const values = new Map<string, string>();
  while (args.length > 0) {
    const name = args.shift();
    if (!name?.startsWith("--")) usage();
    const value = args.shift();
    if (!value || value.startsWith("--")) usage();
    values.set(name, value);
  }
  const required = ["--output", "--iphone-udid", "--catalyst-executable", "--catalyst-dump"];
  if (required.some((key) => !values.has(key))) usage();
  const options: Options = {
    output: resolve(values.get("--output")!),
    iphoneUDID: values.get("--iphone-udid")!,
    catalystExecutable: resolve(values.get("--catalyst-executable")!),
    catalystDump: resolve(values.get("--catalyst-dump")!),
    iphoneActor: values.get("--iphone-actor") ?? "participant-iphone",
    catalystActor: values.get("--catalyst-actor") ?? "owner-catalyst",
  };
  if (!/^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$/.test(options.iphoneUDID)
      || !actors.has(options.iphoneActor)
      || !actors.has(options.catalystActor)
      || options.iphoneActor === options.catalystActor
      || existsSync(options.output)
      || !existsSync(options.catalystExecutable)) {
    console.error("Invalid target, actor, output, or Catalyst executable path.");
    process.exit(64);
  }
  return options;
}

function parseTimestamp(value: unknown): string | null {
  if (typeof value !== "string"
      || !/\.\d{3,}Z$/.test(value)
      || Number.isNaN(Date.parse(value))) return null;
  return value;
}

function validateEvent(value: unknown, runID: string): RelayEvent | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const event = value as Record<string, unknown>;
  const eventTimestamp = parseTimestamp(event.event_timestamp);
  if (!eventTimestamp
      || typeof event.event !== "string" || !events.has(event.event)
      || typeof event.level !== "string" || !levels.has(event.level)
      || typeof event.actor !== "string" || !actors.has(event.actor)
      || event.run_id !== runID
      || !Number.isSafeInteger(event.actor_sequence) || (event.actor_sequence as number) < 1
      || !event.fields || typeof event.fields !== "object" || Array.isArray(event.fields)) {
    return null;
  }
  const fields = event.fields as Record<string, unknown>;
  const safeFields: Record<string, string> = {};
  for (const [key, raw] of Object.entries(fields)) {
    if (!fieldNames.has(key) || typeof raw !== "string" || raw.length > 256) return null;
    safeFields[key] = raw;
  }
  if (safeFields.event_timestamp !== eventTimestamp
      || safeFields.relay_run_id !== runID
      || safeFields.actor !== event.actor
      || safeFields.actor_sequence !== String(event.actor_sequence)) return null;
  return {
    event_timestamp: eventTimestamp,
    event: event.event,
    level: event.level,
    fields: safeFields,
    actor: event.actor,
    run_id: runID,
    actor_sequence: event.actor_sequence as number,
  };
}

function constantTimeEqual(provided: string | undefined, expected: string): boolean {
  if (!provided || provided.length !== expected.length) return false;
  return timingSafeEqual(Buffer.from(provided), Buffer.from(expected));
}

async function readJSON(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += bytes.length;
    if (size > 16 * 1024) throw new Error("body_too_large");
    chunks.push(bytes);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function writeResponse(response: ServerResponse, status: number): void {
  response.writeHead(status, { "Cache-Control": "no-store" });
  response.end();
}

function launchTarget(command: string, args: string[], environment: Record<string, string>): void {
  const result = spawnSync(command, args, { env: { ...process.env, ...environment }, encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`${command} failed: ${result.stderr || result.stdout}`);
  }
}

function processPattern(executable: string): string {
  return `^${executable.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}( |$)`;
}

async function terminateCatalyst(executable: string): Promise<void> {
  const pattern = processPattern(executable);
  const existing = spawnSync("pgrep", ["-f", pattern], { encoding: "utf8" });
  if (existing.status === 1) return;
  if (existing.status !== 0) throw new Error(`Could not inspect existing Catalyst process: ${existing.stderr}`);
  const pids = existing.stdout.trim().split(/\s+/).map(Number).filter(Number.isSafeInteger);
  if (pids.length === 0) throw new Error("Could not determine existing Catalyst process IDs.");
  for (const pid of pids) process.kill(pid, "SIGTERM");
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await Bun.sleep(50);
    const remaining = spawnSync("pgrep", ["-f", pattern], { encoding: "utf8" });
    if (remaining.status === 1) return;
    if (remaining.status !== 0) throw new Error(`Could not confirm Catalyst shutdown: ${remaining.stderr}`);
  }
  throw new Error("Existing Catalyst app did not terminate before relay launch.");
}

function fallbackPathForIPhone(udid: string): string | null {
  const result = spawnSync("xcrun", ["simctl", "get_app_container", udid, bundleID, "data"], { encoding: "utf8" });
  if (result.status !== 0) return null;
  return resolve(result.stdout.trim(), "tmp/rishi-dump/shared-reading.ndjson");
}

function importFallback(
  path: string | null,
  actor: string,
  runID: string,
  seen: Set<string>,
  eventsOut: StoredEvent[],
  counters: { imported: number; unflushed: number; arrival: number },
): void {
  if (!path || !existsSync(path)) {
    counters.unflushed += 1;
    return;
  }
  for (const rawLine of readFileSync(path, "utf8").split("\n")) {
    if (!rawLine) continue;
    let wire: unknown;
    try { wire = JSON.parse(rawLine); } catch { continue; }
    if (!wire || typeof wire !== "object" || Array.isArray(wire)) continue;
    const value = wire as Record<string, unknown>;
    const fields = value.fields;
    if (!fields || typeof fields !== "object" || Array.isArray(fields)) continue;
    const relayFields = fields as Record<string, unknown>;
    if (relayFields.relay_run_id !== runID || relayFields.actor !== actor) continue;
    const imported = validateEvent({
      event_timestamp: relayFields.event_timestamp,
      event: value.message,
      level: value.level,
      fields,
      actor,
      run_id: runID,
      actor_sequence: Number(relayFields.actor_sequence),
    }, runID);
    if (!imported) continue;
    const identity = `${imported.actor}:${imported.actor_sequence}`;
    if (seen.has(identity)) continue;
    seen.add(identity);
    counters.arrival += 1;
    counters.imported += 1;
    eventsOut.push({ ...imported, arrival_timestamp: new Date().toISOString(), arrival_sequence: counters.arrival, source: "fallback-import" });
  }
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  mkdirSync(dirname(options.output), { recursive: true });
  mkdirSync(options.output, { recursive: false });
  const runID = randomBytes(16).toString("base64url");
  const key = randomBytes(32).toString("base64url");
  const received: StoredEvent[] = [];
  const seen = new Set<string>();
  let arrival = 0;
  let closing = false;
  const startedAt = new Date().toISOString();

  const server = createServer(async (request, response) => {
    if (request.method !== "POST" || request.url !== "/events"
        || !constantTimeEqual(request.headers["x-rishi-shared-reading-key"], key)) {
      writeResponse(response, 404);
      return;
    }
    try {
      const event = validateEvent(await readJSON(request), runID);
      if (!event) {
        writeResponse(response, 400);
        return;
      }
      const identity = `${event.actor}:${event.actor_sequence}`;
      if (!seen.has(identity)) {
        seen.add(identity);
        arrival += 1;
        received.push({ ...event, arrival_timestamp: new Date().toISOString(), arrival_sequence: arrival, source: "relay" });
      }
      writeResponse(response, 202);
    } catch {
      writeResponse(response, 400);
    }
  });

  await new Promise<void>((resolveReady) => server.listen(0, "127.0.0.1", resolveReady));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("relay did not bind a loopback port");
  const relayURL = `http://127.0.0.1:${address.port}`;
  const sharedEnvironment = {
    RISHI_SHARED_READING_RELAY_URL: relayURL,
    RISHI_SHARED_READING_RELAY_KEY: key,
    RISHI_SHARED_READING_RELAY_RUN_ID: runID,
  };

  try {
    launchTarget("xcrun", ["simctl", "launch", "--terminate-running-process", options.iphoneUDID, bundleID], {
      SIMCTL_CHILD_RISHI_SHARED_READING_RELAY_URL: relayURL,
      SIMCTL_CHILD_RISHI_SHARED_READING_RELAY_KEY: key,
      SIMCTL_CHILD_RISHI_SHARED_READING_RELAY_RUN_ID: runID,
      SIMCTL_CHILD_RISHI_SHARED_READING_RELAY_ACTOR: options.iphoneActor,
    });
    await terminateCatalyst(options.catalystExecutable);
    const catalyst = spawn(options.catalystExecutable, [], {
      detached: true,
      stdio: "ignore",
      env: { ...process.env, ...sharedEnvironment, RISHI_SHARED_READING_RELAY_ACTOR: options.catalystActor },
    });
    catalyst.unref();
  } catch (error) {
    server.close();
    throw error;
  }

  console.log(`Shared-reading diagnostics active: ${resolve(options.output, "shared-reading.ndjson")}`);
  console.log("Press Ctrl-C only after closing both apps; fallback outboxes will be imported once before finalization.");

  const finish = () => {
    if (closing) return;
    closing = true;
    server.close(() => {
      const counters = { imported: 0, unflushed: 0, arrival };
      importFallback(fallbackPathForIPhone(options.iphoneUDID), options.iphoneActor, runID, seen, received, counters);
      importFallback(resolve(options.catalystDump, "shared-reading.ndjson"), options.catalystActor, runID, seen, received, counters);
      received.sort((left, right) => {
        const time = Date.parse(left.event_timestamp) - Date.parse(right.event_timestamp);
        if (time !== 0) return time;
        if (left.actor === right.actor) {
          const actorSequence = left.actor_sequence - right.actor_sequence;
          if (actorSequence !== 0) return actorSequence;
        }
        return left.arrival_sequence - right.arrival_sequence;
      });
      const output = resolve(options.output, "shared-reading.ndjson");
      const temporary = `${output}.${process.pid}.tmp`;
      writeFileSync(temporary, received.map((event) => JSON.stringify(event)).join("\n") + (received.length ? "\n" : ""), { mode: 0o600 });
      renameSync(temporary, output);
      const manifest = {
        format: "rishi.shared-reading.relay.v1",
        runID,
        startedAt,
        finalizedAt: new Date().toISOString(),
        relay: { loopbackURL: relayURL, clock: "host-wall-clock", received: received.length },
        chronology: ["event_timestamp", "actor_sequence (same actor)", "arrival_sequence"],
        lateImportedEvents: counters.imported,
        unflushedSources: counters.unflushed,
        artifact: "shared-reading.ndjson",
      };
      const manifestPath = resolve(options.output, "manifest.json");
      const manifestTemporary = `${manifestPath}.${process.pid}.tmp`;
      writeFileSync(manifestTemporary, JSON.stringify(manifest, null, 2) + "\n", { mode: 0o600 });
      renameSync(manifestTemporary, manifestPath);
      console.log(`Finalized shared-reading diagnostics: ${output}`);
      process.exit(0);
    });
  };
  process.once("SIGINT", finish);
  process.once("SIGTERM", finish);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : "relay failed");
  process.exit(1);
});
