import { inArray } from "drizzle-orm";

import type { WorkerDb } from "./db/drizzle";
import { user } from "./db/schema";
import { referencedR2Keys } from "./shares/shareReferences";

export const ACCOUNT_R2_CHECKPOINT_PREFIX = "_maintenance/account-r2-reconciliation/v1/";
export const ACCOUNT_R2_RECONCILIATION_PREFIXES = ["books/", "covers/"] as const;
export type AccountR2Prefix = "books/" | "covers/";

export interface AccountR2SweepResult {
  prefix: AccountR2Prefix;
  scanned: number;
  deleted: number;
  cycleCompleted: boolean;
  checkpoint: "advanced" | "contended";
}

export type AccountR2SweepError = Error & {
  code: "ACCOUNT_R2_SWEEP_FAILED";
  phase: "checkpoint" | "list" | "owners" | "references" | "delete";
  retryable: true;
};

type AccountR2SweepPhase = AccountR2SweepError["phase"];

type AccountR2Checkpoint = {
  version: 1;
  revision: string;
  cursor: string | null;
  cycleStartedAt: number;
  cycleCompletedAt: number | null;
};

type ObservedCheckpoint = {
  checkpoint: AccountR2Checkpoint;
  etag?: string;
};

const ACCOUNT_R2_PAGE_LIMIT = 100;
const ACCOUNT_R2_REFERENCE_CHUNK_SIZE = 49;

function sweepError(
  phase: AccountR2SweepPhase,
  message: string,
  cause?: unknown,
): AccountR2SweepError {
  const error = new Error(message) as AccountR2SweepError;
  error.name = "AccountR2SweepError";
  error.code = "ACCOUNT_R2_SWEEP_FAILED";
  error.phase = phase;
  error.retryable = true;
  if (cause !== undefined) error.cause = cause;
  return error;
}

function checkpointKey(prefix: AccountR2Prefix): string {
  return `${ACCOUNT_R2_CHECKPOINT_PREFIX}${prefix.slice(0, -1)}.json`;
}

function nextRevision(): string {
  return crypto.randomUUID();
}

function isPrefix(value: string): value is AccountR2Prefix {
  return (ACCOUNT_R2_RECONCILIATION_PREFIXES as readonly string[]).includes(value);
}

function isCheckpoint(value: unknown): value is AccountR2Checkpoint {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  if (keys.join(",") !== "cursor,cycleCompletedAt,cycleStartedAt,revision,version") return false;
  return record.version === 1
    && typeof record.revision === "string" && record.revision.length > 0
    && (record.cursor === null || typeof record.cursor === "string")
    && typeof record.cycleStartedAt === "number"
    && Number.isSafeInteger(record.cycleStartedAt)
    && record.cycleStartedAt >= 0
    && (record.cycleCompletedAt === null
      || (typeof record.cycleCompletedAt === "number"
        && Number.isSafeInteger(record.cycleCompletedAt)
        && record.cycleCompletedAt >= 0));
}

function freshCheckpoint(nowMs: number): AccountR2Checkpoint {
  return {
    version: 1,
    revision: nextRevision(),
    cursor: null,
    cycleStartedAt: nowMs,
    cycleCompletedAt: null,
  };
}

async function resetMalformedCheckpoint(
  bucket: R2Bucket,
  prefix: AccountR2Prefix,
  etag: string,
  nowMs: number,
): Promise<void> {
  try {
    await bucket.put(checkpointKey(prefix), JSON.stringify(freshCheckpoint(nowMs)), {
      onlyIf: { etagMatches: etag },
      httpMetadata: { contentType: "application/json" },
    });
  } catch (error) {
    throw sweepError("checkpoint", "Unable to reset malformed R2 reconciliation checkpoint", error);
  }
}

async function readCheckpoint(
  bucket: R2Bucket,
  prefix: AccountR2Prefix,
  nowMs: number,
): Promise<ObservedCheckpoint> {
  const key = checkpointKey(prefix);
  let object: R2ObjectBody | null;
  try {
    object = await bucket.get(key);
  } catch (error) {
    throw sweepError("checkpoint", "Unable to read R2 reconciliation checkpoint", error);
  }

  if (!object) return { checkpoint: freshCheckpoint(nowMs) };

  let parsed: unknown;
  try {
    parsed = JSON.parse(await object.text());
  } catch (error) {
    await resetMalformedCheckpoint(bucket, prefix, object.etag, nowMs);
    throw sweepError("checkpoint", "Malformed R2 reconciliation checkpoint", error);
  }
  if (!isCheckpoint(parsed)) {
    await resetMalformedCheckpoint(bucket, prefix, object.etag, nowMs);
    throw sweepError("checkpoint", "Malformed R2 reconciliation checkpoint");
  }
  return { checkpoint: parsed, etag: object.etag };
}

function ownerFromKey(prefix: AccountR2Prefix, key: string): string | undefined {
  if (!key.startsWith(prefix)) return undefined;
  const remainder = key.slice(prefix.length);
  const separator = remainder.indexOf("/");
  if (separator <= 0 || separator === remainder.length - 1) return undefined;
  return remainder.slice(0, separator);
}

async function liveOwnerIds(db: WorkerDb, ownerIds: string[]): Promise<Set<string>> {
  if (ownerIds.length === 0) return new Set();
  try {
    const rows = await db.select({ id: user.id }).from(user).where(inArray(user.id, ownerIds)).all();
    return new Set(rows.map((row) => row.id));
  } catch (error) {
    throw sweepError("owners", "Unable to resolve R2 object owners", error);
  }
}

async function referencedKeys(db: WorkerDb, keys: string[]): Promise<Set<string>> {
  try {
    const references = new Set<string>();
    for (let offset = 0; offset < keys.length; offset += ACCOUNT_R2_REFERENCE_CHUNK_SIZE) {
      const chunk = keys.slice(offset, offset + ACCOUNT_R2_REFERENCE_CHUNK_SIZE);
      const chunkReferences = await referencedR2Keys(db, chunk);
      for (const key of chunkReferences) references.add(key);
    }
    return references;
  } catch (error) {
    throw sweepError("references", "Unable to resolve R2 object references", error);
  }
}

async function advanceCheckpoint(
  bucket: R2Bucket,
  prefix: AccountR2Prefix,
  checkpoint: AccountR2Checkpoint,
  etag: string | undefined,
): Promise<"advanced" | "contended"> {
  let written: R2Object | null;
  try {
    written = await bucket.put(checkpointKey(prefix), JSON.stringify(checkpoint), {
      onlyIf: etag !== undefined ? { etagMatches: etag } : { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "application/json" },
    });
  } catch (error) {
    throw sweepError("checkpoint", "Unable to advance R2 reconciliation checkpoint", error);
  }
  return written ? "advanced" : "contended";
}

/** Process exactly one bounded reconciliation page for one account-owned prefix. */
export async function reconcileAccountR2Page(
  db: WorkerDb,
  bucket: R2Bucket,
  prefix: AccountR2Prefix,
  nowMs: number,
): Promise<AccountR2SweepResult> {
  if (!isPrefix(prefix)) throw sweepError("list", "Unsupported account R2 reconciliation prefix");

  const stored = await readCheckpoint(bucket, prefix, nowMs);
  const prior = stored.checkpoint;
  const checkpointAtStart = prior.cursor === null && prior.cycleCompletedAt !== null
    ? { ...prior, revision: nextRevision(), cycleStartedAt: nowMs }
    : prior;

  let page: R2Objects;
  try {
    page = await bucket.list({
      prefix,
      limit: ACCOUNT_R2_PAGE_LIMIT,
      ...(checkpointAtStart.cursor !== null ? { cursor: checkpointAtStart.cursor } : {}),
    });
  } catch (error) {
    throw sweepError("list", "Unable to list R2 account objects", error);
  }
  if (page.truncated && !page.cursor) {
    throw sweepError("list", "R2 returned a truncated page without a cursor");
  }

  const listedKeys = page.objects
    .map((object) => object.key)
    .filter((key) => ownerFromKey(prefix, key) !== undefined);
  const ownerIds = [...new Set(listedKeys.map((key) => ownerFromKey(prefix, key)!))];
  const owners = await liveOwnerIds(db, ownerIds);
  const candidates = listedKeys.filter((key) => !owners.has(ownerFromKey(prefix, key)!));
  const references = await referencedKeys(db, candidates);
  const removable = candidates.filter((key) => !references.has(key));

  let deleted = 0;
  if (removable.length > 0) {
    try {
      await bucket.delete(removable);
      deleted = removable.length;
    } catch (error) {
      throw sweepError("delete", "Unable to delete an unreferenced R2 account object", error);
    }
  }

  const nextCursor = page.truncated ? page.cursor : null;
  const cycleCompleted = nextCursor === null;
  const nextCheckpoint: AccountR2Checkpoint = {
    version: 1,
    revision: nextRevision(),
    cursor: nextCursor,
    cycleStartedAt: checkpointAtStart.cycleStartedAt,
    cycleCompletedAt: cycleCompleted ? nowMs : checkpointAtStart.cycleCompletedAt,
  };
  const checkpoint = await advanceCheckpoint(bucket, prefix, nextCheckpoint, stored.etag);

  return {
    prefix,
    scanned: page.objects.length,
    deleted,
    cycleCompleted,
    checkpoint,
  };
}
