import { Hono } from "hono";
import { aliasedTable, and, asc, eq, gt, gte, lte, notExists, or, type AnyColumn } from "drizzle-orm";

import { requireAuth } from "../index";
import { requireAiDataConsent } from "../middleware/ai-data-consent";
import { createDb } from "../db/drizzle";
import { books, highlights, bookmarks, chapterIndexes, chapterIndexChapters } from "../db/schema";
import {
  compareSyncCursorTuple,
  decodeSyncCursor,
  encodeSyncCursor,
  type SyncChangeKind,
  type SyncCursor,
} from "../sync/change-cursor";

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
const CHAPTER_CHILD_BATCH_SIZE = 100;
const SNAPSHOT_HASH_VERSION = "sync-json-v1";

function cursorWhere(
  userColumn: AnyColumn,
  updatedColumn: AnyColumn,
  idColumn: AnyColumn,
  kind: SyncChangeKind,
  userId: string,
  cursor: SyncCursor | null,
  highWaterMs: number,
) {
  const withinHighWater = lte(updatedColumn, highWaterMs);
  if (!cursor) return and(eq(userColumn, userId), withinHighWater);

  const afterCursor = kind > cursor.kind
    ? gte(updatedColumn, cursor.updatedAtMs)
    : kind < cursor.kind
      ? gt(updatedColumn, cursor.updatedAtMs)
      : or(
        gt(updatedColumn, cursor.updatedAtMs),
        and(eq(updatedColumn, cursor.updatedAtMs), gt(idColumn, cursor.id)),
      );
  return and(eq(userColumn, userId), withinHighWater, afterCursor);
}

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
  const rawCursor = c.req.query("cursor");
  const rawScope = c.req.query("scope");
  const isLegacyRequest = rawCursor === undefined && rawSince !== undefined;
  let cursor: SyncCursor | null = null;
  if (rawCursor !== undefined) {
    try {
      cursor = decodeSyncCursor(rawCursor);
    } catch {
      return c.json({ error: "cursor must be a valid sync cursor" }, 400);
    }
  }
  if (rawScope !== undefined && rawScope !== "incremental" && rawScope !== "full") {
    return c.json({ error: "scope must be incremental or full" }, 400);
  }
  if (rawCursor !== undefined && rawScope !== undefined && rawScope !== cursor?.scope) {
    return c.json({ error: "scope does not match cursor" }, 400);
  }
  let sinceMs: number | null = null;
  if (isLegacyRequest && rawSince !== undefined) {
    const parsed = Date.parse(rawSince);
    if (Number.isNaN(parsed)) {
      return c.json({ error: "since must be a valid ISO8601 timestamp" }, 400);
    }
    sinceMs = parsed;
  }
  const userId = c.get("userId");
  const db = createDb(c.env.DB);
  const cursorRequest = !isLegacyRequest;
  const requestedScope = cursor?.scope ?? (rawScope === "full" ? "full" : "incremental");
  const highWaterMs = cursor?.highWaterMs ?? Date.now();

  const bookWhere =
    cursorRequest
      ? cursorWhere(books.userId, books.updatedAt, books.id, "book", userId, cursor, highWaterMs)
      : sinceMs === null
      ? eq(books.userId, userId)
      : and(eq(books.userId, userId), gt(books.updatedAt, sinceMs));
  const highlightWhere =
    cursorRequest
      ? cursorWhere(highlights.userId, highlights.updatedAt, highlights.id, "highlight", userId, cursor, highWaterMs)
      : sinceMs === null
      ? eq(highlights.userId, userId)
      : and(eq(highlights.userId, userId), gt(highlights.updatedAt, sinceMs));
  const bookmarkWhere =
    cursorRequest
      ? cursorWhere(bookmarks.userId, bookmarks.updatedAt, bookmarks.id, "bookmark", userId, cursor, highWaterMs)
      : sinceMs === null
      ? eq(bookmarks.userId, userId)
      : and(eq(bookmarks.userId, userId), gt(bookmarks.updatedAt, sinceMs));
  const chapterIndexWhere =
    cursorRequest
      ? cursorWhere(chapterIndexes.userId, chapterIndexes.updatedAt, chapterIndexes.bookId, "chapter_index", userId, cursor, highWaterMs)
      : sinceMs === null
      ? eq(chapterIndexes.userId, userId)
      : and(eq(chapterIndexes.userId, userId), gt(chapterIndexes.updatedAt, sinceMs));

  // A book may have multiple chapter-index content versions, but the sync
  // projection intentionally exposes only the latest version for each book.
  // Select that latest row in SQL before applying the page limit; limiting raw
  // history first can otherwise return stale versions or repeat a book across
  // pages. Cursor-mode high-water filtering belongs in the anti-join too: a
  // write after the page's high water must not hide the latest visible row.
  const newerChapterIndex = aliasedTable(chapterIndexes, "newer_chapter_index");
  const chapterLatestWhere = and(
    chapterIndexWhere,
    notExists(
      db
        .select({ id: newerChapterIndex.id })
        .from(newerChapterIndex)
        .where(and(
          eq(newerChapterIndex.userId, userId),
          eq(newerChapterIndex.bookId, chapterIndexes.bookId),
          ...(cursorRequest ? [lte(newerChapterIndex.updatedAt, highWaterMs)] : []),
          or(
            gt(newerChapterIndex.updatedAt, chapterIndexes.updatedAt),
            and(
              eq(newerChapterIndex.updatedAt, chapterIndexes.updatedAt),
              or(
                gt(newerChapterIndex.contentVersion, chapterIndexes.contentVersion),
                and(
                  eq(newerChapterIndex.contentVersion, chapterIndexes.contentVersion),
                  gt(newerChapterIndex.id, chapterIndexes.id),
                ),
              ),
            ),
          ),
        )),
    ),
  );

  const pageLimit = cursorRequest ? PULL_LIMIT + 1 : PULL_LIMIT;
  const bookRows = await db
    .select()
    .from(books)
    .where(bookWhere)
    .orderBy(asc(books.updatedAt), asc(books.id))
    .limit(pageLimit)
    .all();
  const highlightRows = await db
    .select()
    .from(highlights)
    .where(highlightWhere)
    .orderBy(asc(highlights.updatedAt), asc(highlights.id))
    .limit(pageLimit)
    .all();
  const bookmarkRows = await db
    .select()
    .from(bookmarks)
    .where(bookmarkWhere)
    .orderBy(asc(bookmarks.updatedAt), asc(bookmarks.id))
    .limit(pageLimit)
    .all();
  const chapterIndexRows = await db
    .select()
    .from(chapterIndexes)
    .where(chapterLatestWhere)
    .orderBy(asc(chapterIndexes.updatedAt), asc(chapterIndexes.bookId))
    .limit(pageLimit)
    .all();
  // Keep a deterministic in-memory guard as well. Production SQL returns one
  // row per book; this protects the projection if a legacy database or test
  // adapter does not support the anti-join semantics yet.
  const latestChapterByBook = new Map<string, (typeof chapterIndexRows)[number]>();
  for (const row of chapterIndexRows) {
    if (sinceMs !== null && !cursorRequest && row.updatedAt <= sinceMs) continue;
    const current = latestChapterByBook.get(row.bookId);
    if (
      !current ||
      row.updatedAt > current.updatedAt ||
      (row.updatedAt === current.updatedAt && (
        row.contentVersion > current.contentVersion ||
        (row.contentVersion === current.contentVersion && row.id > current.id)
      ))
    ) {
      latestChapterByBook.set(row.bookId, row);
    }
  }
  const latestChapterRows = [...latestChapterByBook.values()]
    .sort((a, b) =>
      a.updatedAt - b.updatedAt ||
      (a.bookId < b.bookId ? -1 : a.bookId > b.bookId ? 1 : 0),
    );

  // ── Map rows to SyncChange envelopes ────────────────────────────────
  interface Change {
    kind: SyncChangeKind;
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
  const truncatedChapterKeys = new Set<string>();
  let childBudget = CHAPTER_CHILD_LIMIT;
  let hasTruncatedChapterChildren = false;
  for (let start = 0; start < latestChapterRows.length; start += CHAPTER_CHILD_BATCH_SIZE) {
    const batch = latestChapterRows.slice(start, start + CHAPTER_CHILD_BATCH_SIZE);
    const batchKeys = batch.map((row) => `${row.bookId}:${row.contentVersion}`);
    if (childBudget <= 0) {
      hasTruncatedChapterChildren = true;
      for (const key of batchKeys) truncatedChapterKeys.add(key);
      continue;
    }

    const exactKeys = or(...batch.map((row) => and(
      eq(chapterIndexChapters.bookId, row.bookId),
      eq(chapterIndexChapters.contentVersion, row.contentVersion),
    )));
    const queryLimit = childBudget + batch.length;
    const childRows = await db
      .select()
      .from(chapterIndexChapters)
      .where(and(eq(chapterIndexChapters.userId, userId), exactKeys))
      .orderBy(
        asc(chapterIndexChapters.bookId),
        asc(chapterIndexChapters.contentVersion),
        asc(chapterIndexChapters.sourcePosition),
      )
      .limit(queryLimit)
      .all() as unknown as Array<Record<string, unknown>>;
    const queryWasCapped = childRows.length >= queryLimit;
    const rowsByKey = new Map<string, Array<Record<string, unknown>>>();
    for (const child of childRows) {
      const key = `${child.bookId}:${child.contentVersion}`;
      const rows = rowsByKey.get(key) ?? [];
      rows.push(child);
      rowsByKey.set(key, rows);
    }

    for (const key of batchKeys) {
      const rows = rowsByKey.get(key) ?? [];
      if (queryWasCapped) truncatedChapterKeys.add(key);
      if (childBudget <= 0) {
        truncatedChapterKeys.add(key);
        hasTruncatedChapterChildren = true;
        childrenByVersion.set(key, []);
        continue;
      }
      const retained = rows.slice(0, Math.min(CHAPTER_CHILD_LIMIT, childBudget));
      childrenByVersion.set(key, retained);
      if (retained.length < rows.length || truncatedChapterKeys.has(key)) {
        truncatedChapterKeys.add(key);
        hasTruncatedChapterChildren = true;
      }
      childBudget -= retained.length;
    }
  }

  for (const row of latestChapterRows as unknown as Array<Record<string, unknown>>) {
    const updatedAt = row.updatedAt as number;
    const allChildRowsForIndex = childrenByVersion.get(`${row.bookId}:${row.contentVersion}`) ?? [];
    const chaptersTruncated = truncatedChapterKeys.has(`${row.bookId}:${row.contentVersion}`);
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
    (a, b) => compareSyncCursorTuple(
      { updatedAtMs: a.__sortKey, kind: a.kind, id: a.id },
      { updatedAtMs: b.__sortKey, kind: b.kind, id: b.id },
    ),
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
  const cursorChanges = changes
    .filter((change) => change.__sortKey <= highWaterMs)
    .filter((change) =>
      cursor === null || compareSyncCursorTuple(
        { updatedAtMs: change.__sortKey, kind: change.kind, id: change.id },
        cursor,
      ) > 0,
    );
  const pageChanges = cursorRequest
    ? cursorChanges.slice(0, PULL_LIMIT)
    : changes
      .filter((change) => change.__sortKey <= safeCutoff)
      .slice(0, PULL_LIMIT);
  const sanitized = pageChanges.map(({ __sortKey: _s, ...rest }) => {
    void _s;
    return rest;
  });
  const hasMore = cursorRequest && cursorChanges.length > PULL_LIMIT;
  const projectionComplete = cursorRequest
    ? !hasMore && !hasTruncatedChapterChildren
    : !(
      truncatedTypes.length > 0 ||
      changes.length > PULL_LIMIT ||
      hasTruncatedChapterChildren
    );
  const hashInput = [...sanitized].sort(
    (left, right) =>
      (left.kind < right.kind ? -1 : left.kind > right.kind ? 1 : 0) ||
      (left.id < right.id ? -1 : left.id > right.id ? 1 : 0),
  );
  if (!cursorRequest) {
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
  }

  const lastChange = pageChanges.at(-1);
  const nextCursor = hasMore && lastChange
    ? encodeSyncCursor({
      v: 1,
      scope: requestedScope,
      highWaterMs,
      updatedAtMs: lastChange.__sortKey,
      kind: lastChange.kind,
      id: lastChange.id,
    })
    : null;
  return c.json({
    changes: sanitized,
    next_cursor: nextCursor,
    has_more: hasMore,
    cursor_scope: requestedScope,
    projection_complete: projectionComplete,
    is_truncated: !projectionComplete,
    ...(projectionComplete && !hasMore
      ? {
        // Hashes are terminal-page metadata only. Non-terminal pages must be
        // resumed with their cursor instead of being mistaken for a complete
        // projection.
        snapshot_hash: await hashSyncProjectionWithTimestamps(hashInput),
        snapshot_hash_without_timestamps: await hashSyncProjection(hashInput),
        snapshot_hash_version: SNAPSHOT_HASH_VERSION,
      }
      : {}),
  });
});
