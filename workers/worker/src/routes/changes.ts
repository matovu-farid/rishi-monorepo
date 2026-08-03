import { Hono } from "hono";
import { and, asc, eq, gt } from "drizzle-orm";

import { requireAuth } from "../index";
import { requireAiDataConsent } from "../middleware/ai-data-consent";
import { createDb } from "../db/drizzle";
import { books, highlights, bookmarks, chapterIndexes, chapterIndexChapters } from "../db/schema";

/**
 * GET /api/sync/changes?since=<ISO8601>
 *
 * Inbound bridge that closes the Phase-7 audit gap where iOS
 * RishiSync/Inbound/RemoteChangeFetcher.swift calls a route the worker
 * never shipped (live probe was 404). With this handler mounted iOS can
 * pull the caller's books + highlights back from D1 on every sync tick.
 *
 * Response envelope matches the iOS SyncChange contract verbatim — see
 * apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/SyncAPI.swift
 * lines 89-108 (SyncChange) + 212-216 (SyncChangesResponse):
 *
 *   { changes: [
 *       { kind: "book"|"highlight", id: <uuid>, payload: {...},
 *         updated_at: <number>, deleted: <bool> }, ...
 *   ] }
 *
 * v1 kinds: "book", "highlight". Deferred to v1.1: explicit "position"
 * (rides inside the book payload via current_cfi / current_page /
 * last_progress_percent), "conversation" + "message" (Phase 16 already
 * handles via /api/sync/conversations + /api/sync/messages).
 *
 * updated_at wire format: JSON number = seconds since reference date
 * 2001-01-01T00:00:00Z, matching the .deferredToDate strategy of the
 * bare JSONDecoder() that
 * apps/apple/Packages/RishiAPI/Sources/RishiAPI/WorkerClient.swift:96
 * uses. Confirmed by SyncEngineTests.swift:309 (`Date wire = seconds
 * since reference date (2001-01-01) — matches default JSONDecoder.`)
 * and the parity comment in VerifyReceiptAPI.swift:22. Reference offset
 * constant: 978_307_200_000 ms (the 1970->2001 gap).
 */

const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
const PULL_LIMIT = 5000;
const CHAPTER_CHILD_LIMIT = 5000;

function toSecondsSinceRefDate(msEpoch: number): number {
  return (msEpoch - REFERENCE_DATE_OFFSET_MS) / 1000;
}

/**
 * Canonical JSON for the sync projection. JSON.stringify preserves insertion
 * order, which is not a protocol guarantee when rows are assembled by
 * different query paths. Sorting object keys recursively makes the digest
 * independent of database/JavaScript object construction order.
 */
export function canonicalizeSyncJSON(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalizeSyncJSON).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, item]) => item !== undefined)
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
  return `{${entries
    .map(([key, item]) => `${JSON.stringify(key)}:${canonicalizeSyncJSON(item)}`)
    .join(",")}}`;
}

/**
 * Remove timestamps from the generated projection before equality hashing.
 * Timestamps remain part of the wire object and are still used for LWW
 * conflict resolution; they are excluded only from convergence comparison so
 * clock/precision differences between Apple and JavaScript cannot create a
 * false mismatch.
 */
export function stripSyncTimestamps(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripSyncTimestamps);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .filter(([key]) => {
        const normalized = key.replaceAll("-", "_").toLowerCase();
        return normalized !== "created_at" && normalized !== "updated_at";
      })
      .map(([key, item]) => [key, stripSyncTimestamps(item)]),
  );
}

export async function hashSyncProjection(value: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalizeSyncJSON(stripSyncTimestamps(value)));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Legacy digest retained for older Apple builds during Worker rollout. */
export async function hashSyncProjectionWithTimestamps(value: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalizeSyncJSON(value));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export const changesRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

changesRoutes.get("/", requireAuth, requireAiDataConsent, async (c) => {
  const rawSince = c.req.query("since");
  let sinceMs: number | null = null;
  if (rawSince !== undefined) {
    const parsed = Date.parse(rawSince);
    if (Number.isNaN(parsed)) {
      return c.json({ error: "since must be a valid ISO8601 timestamp" }, 400);
    }
    sinceMs = parsed;
  }
  const userId = c.get("userId");
  const db = createDb(c.env.DB);

  const bookWhere =
    sinceMs === null
      ? eq(books.userId, userId)
      : and(eq(books.userId, userId), gt(books.updatedAt, sinceMs));
  const highlightWhere =
    sinceMs === null
      ? eq(highlights.userId, userId)
      : and(eq(highlights.userId, userId), gt(highlights.updatedAt, sinceMs));
  const bookmarkWhere =
    sinceMs === null
      ? eq(bookmarks.userId, userId)
      : and(eq(bookmarks.userId, userId), gt(bookmarks.updatedAt, sinceMs));
  const chapterIndexWhere =
    sinceMs === null
      ? eq(chapterIndexes.userId, userId)
      : and(eq(chapterIndexes.userId, userId), gt(chapterIndexes.updatedAt, sinceMs));

  const bookRows = await db
    .select()
    .from(books)
    .where(bookWhere)
    .orderBy(asc(books.updatedAt))
    .limit(PULL_LIMIT)
    .all();
  const highlightRows = await db
    .select()
    .from(highlights)
    .where(highlightWhere)
    .orderBy(asc(highlights.updatedAt))
    .limit(PULL_LIMIT)
    .all();
  const bookmarkRows = await db
    .select()
    .from(bookmarks)
    .where(bookmarkWhere)
    .orderBy(asc(bookmarks.updatedAt))
    .limit(PULL_LIMIT)
    .all();
  const chapterIndexRows = await db
    .select()
    .from(chapterIndexes)
    .where(chapterIndexWhere)
    .orderBy(asc(chapterIndexes.updatedAt))
    .all();

  const latestChapterByBook = new Map<string, (typeof chapterIndexRows)[number]>();
  for (const row of chapterIndexRows) {
    const current = latestChapterByBook.get(row.bookId);
    if (!current || row.updatedAt > current.updatedAt) latestChapterByBook.set(row.bookId, row);
  }
  const latestChapterRows = [...latestChapterByBook.values()]
    .filter((row) => sinceMs === null || row.updatedAt > sinceMs)
    .sort((a, b) => a.updatedAt - b.updatedAt)
    .slice(0, PULL_LIMIT);

  // ── Map rows to SyncChange envelopes ────────────────────────────────
  interface Change {
    kind: "book" | "highlight" | "bookmark" | "chapter_index";
    id: string;
    payload: Record<string, unknown>;
    updated_at: number;
    deleted: boolean;
    __sortKey: number; // private — stripped before response
  }

  const changes: Change[] = [];

  for (const row of bookRows as unknown as Array<Record<string, unknown>>) {
    // Explicitly map the worker's Drizzle keys to the iOS wire contract.
    // file_path/cover_path are local-only and must never cross this boundary.
    const id = row.id as string;
    const updatedAt = row.updatedAt as number;
    const isDeleted = !!row.isDeleted;
    changes.push({
      kind: "book",
      id,
      payload: {
        id,
        title: row.title,
        author: row.author,
        format_type: row.format,
        current_cfi: row.currentCfi,
        current_page: row.currentPage,
        last_progress_percent: row.lastProgressPercent,
        file_hash: row.fileHash,
        file_r2_key: row.fileR2Key,
        cover_r2_key: row.coverR2Key,
        file_size: row.fileSize,
        created_at:
          typeof row.createdAt === "number"
            ? new Date(row.createdAt).toISOString() // WIRE-ISO8601-PAYLOAD
            : null,
      },
      updated_at: toSecondsSinceRefDate(updatedAt),
      deleted: isDeleted,
      __sortKey: updatedAt,
    });
  }

  for (const row of highlightRows as unknown as Array<
    Record<string, unknown>
  >) {
    const updatedAt = row.updatedAt as number;
    const isDeleted = !!row.isDeleted;
    // Map Drizzle's camelCase columns to the snake_case wire contract. Do
    // not spread the row: the client decoder intentionally only understands
    // the portable metadata fields below.
    const payload = {
      id: row.id as string,
      book_id: row.bookId as string,
      locator_start: row.cfiRange as string,
      // D1 currently stores one canonical CFI range. Mirror it in both
      // wire endpoints so the Apple decoder can materialize the range even
      // for rows created by older clients that did not persist a separate
      // end locator.
      locator_end: row.cfiRange as string,
      text: row.text as string,
      color: row.color as string,
      note: row.note ?? null,
      chapter: row.chapter ?? null,
      created_at:
        typeof row.createdAt === "number"
          ? new Date(row.createdAt).toISOString() // WIRE-ISO8601-PAYLOAD
          : null,
    };
    changes.push({
      kind: "highlight",
      id: row.id as string,
      payload,
      updated_at: toSecondsSinceRefDate(updatedAt),
      deleted: isDeleted,
      __sortKey: updatedAt,
    });
  }

  for (const row of bookmarkRows as unknown as Array<Record<string, unknown>>) {
    const updatedAt = row.updatedAt as number;
    const isDeleted = !!row.isDeleted;
    // NAME MISMATCH: column `location` -> wire `locator` (inverse of the
    // sync.ts push arm). created_at is an ISO8601 STRING because the iOS
    // SyncPayloadCodec decodes PAYLOAD dates with .iso8601 (NOT the envelope's
    // .deferredToDate seconds-since-2001). row.createdAt is integer ms epoch.
    const createdAtMs = row.createdAt as number | null | undefined;
    const createdAtIso =
      typeof createdAtMs === "number"
        ? new Date(createdAtMs).toISOString() // WIRE-ISO8601-PAYLOAD: payload-internal date, decoded by SyncPayloadCodec .iso8601, NOT the envelope .deferredToDate field
        : null;
    changes.push({
      kind: "bookmark",
      id: row.id as string,
      payload: {
        id: row.id as string,
        book_id: row.bookId as string,
        locator: row.location as string,
        label: (row.label as string | null) ?? null,
        snippet: (row.snippet as string | null) ?? null,
        created_at: createdAtIso,
      },
      updated_at: toSecondsSinceRefDate(updatedAt),
      deleted: isDeleted,
      __sortKey: updatedAt,
    });
  }

  const childrenByVersion = new Map<string, Array<Record<string, unknown>>>();
  let childBudget = CHAPTER_CHILD_LIMIT;
  let hasTruncatedChapterChildren = false;
  for (const row of latestChapterRows) {
    const key = `${row.bookId}:${row.contentVersion}`;
    if (childBudget <= 0) continue;
    const rows = await db
      .select()
      .from(chapterIndexChapters)
      .where(and(
        eq(chapterIndexChapters.userId, userId),
        eq(chapterIndexChapters.bookId, row.bookId),
        eq(chapterIndexChapters.contentVersion, row.contentVersion),
      ))
      .orderBy(asc(chapterIndexChapters.sourcePosition))
      .limit(Math.min(CHAPTER_CHILD_LIMIT + 1, childBudget + 1))
      .all();
    childrenByVersion.set(key, rows as unknown as Array<Record<string, unknown>>);
    if (rows.length > CHAPTER_CHILD_LIMIT) hasTruncatedChapterChildren = true;
    childBudget -= Math.min(rows.length, CHAPTER_CHILD_LIMIT);
  }

  for (const row of latestChapterRows as unknown as Array<Record<string, unknown>>) {
    const updatedAt = row.updatedAt as number;
    const allChildRowsForIndex = childrenByVersion.get(`${row.bookId}:${row.contentVersion}`) ?? [];
    const chaptersTruncated = allChildRowsForIndex.length > CHAPTER_CHILD_LIMIT;
    const childRowsForIndex = allChildRowsForIndex.slice(0, CHAPTER_CHILD_LIMIT);
    changes.push({
      kind: "chapter_index",
      id: row.bookId as string,
      payload: {
        id: row.id as string,
        book_id: row.bookId as string,
        content_version: row.contentVersion as string,
        status: row.status as string,
        model_identifier: row.modelIdentifier as string,
        model_version: row.modelVersion as string,
        progress: { completed: row.completedCount, total: row.totalCount },
        error_message: row.errorMessage ?? null,
        created_at: typeof row.createdAt === "number" ? new Date(row.createdAt).toISOString() : null, // WIRE-ISO8601-PAYLOAD
        updated_at: typeof row.updatedAt === "number" ? new Date(row.updatedAt).toISOString() : null, // WIRE-ISO8601-PAYLOAD
        chapters: childRowsForIndex.map((child) => ({
          id: child.chapterId,
          name: child.name,
          summary: child.summary,
          source_position: child.sourcePosition,
        })),
        chapters_truncated: chaptersTruncated,
      },
      updated_at: toSecondsSinceRefDate(updatedAt),
      deleted: false,
      __sortKey: updatedAt,
    });
  }

  // Sort ASC by updatedAt across ALL kinds so the iOS ChangeApplier sees
  // a stable, monotonically-increasing iteration order. Within-kind order
  // already comes from the .orderBy(asc(...)) clauses above; this final
  // sort interleaves books + highlights correctly.
  changes.sort(
    (a, b) =>
      a.__sortKey - b.__sortKey ||
      (a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : 0) ||
      (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );
  const truncatedTypes = [
    bookRows.length >= PULL_LIMIT ? bookRows.at(-1)?.updatedAt : undefined,
    highlightRows.length >= PULL_LIMIT ? highlightRows.at(-1)?.updatedAt : undefined,
    bookmarkRows.length >= PULL_LIMIT ? bookmarkRows.at(-1)?.updatedAt : undefined,
    latestChapterRows.length >= PULL_LIMIT ? latestChapterRows.at(-1)?.updatedAt : undefined,
  ].filter((value): value is number => typeof value === "number");
  // The client has a single timestamp cursor. If one type was truncated, do
  // not return another type beyond that type's safe boundary; otherwise the
  // client could advance past omitted rows. Include the boundary row so the
  // legacy timestamp cursor can advance.
  const safeCutoff = truncatedTypes.length > 0
    ? Math.min(...truncatedTypes)
    : Number.POSITIVE_INFINITY;
  const sanitized = changes
    .filter((change) => change.__sortKey <= safeCutoff)
    .slice(0, PULL_LIMIT)
    .map(({ __sortKey: _s, ...rest }) => {
    void _s;
    return rest;
    });
  const hashInput = [...sanitized].sort(
    (left, right) =>
      (left.kind < right.kind ? -1 : left.kind > right.kind ? 1 : 0) ||
      (left.id < right.id ? -1 : left.id > right.id ? 1 : 0),
  );
  const snapshotHash = await hashSyncProjectionWithTimestamps(hashInput);
  const timestampFreeSnapshotHash = await hashSyncProjection(hashInput);

  return c.json({
    changes: sanitized,
    snapshot_hash: snapshotHash,
    snapshot_hash_without_timestamps: timestampFreeSnapshotHash,
    is_truncated:
      truncatedTypes.length > 0 ||
      changes.length > PULL_LIMIT ||
      hasTruncatedChapterChildren,
  });
});
