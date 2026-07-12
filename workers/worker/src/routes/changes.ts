import { Hono } from "hono";
import { and, asc, eq, gt } from "drizzle-orm";

import { requireAuth } from "../index";
import { createDb } from "../db/drizzle";
import { books, highlights, bookmarks } from "@rishi/shared/schema";

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

function toSecondsSinceRefDate(msEpoch: number): number {
  return (msEpoch - REFERENCE_DATE_OFFSET_MS) / 1000;
}

export const changesRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

changesRoutes.get("/", requireAuth, async (c) => {
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

  // ── Map rows to SyncChange envelopes ────────────────────────────────
  interface Change {
    kind: "book" | "highlight" | "bookmark";
    id: string;
    payload: Record<string, unknown>;
    updated_at: number;
    deleted: boolean;
    __sortKey: number; // private — stripped before response
  }

  const changes: Change[] = [];

  for (const row of bookRows as unknown as Array<Record<string, unknown>>) {
    // STRIP file_path + cover_path — local-only paths, same rule as the
    // existing sync.ts /pull handler at line 396-400.
    const {
      filePath: _fp,
      coverPath: _cp,
      id,
      updatedAt,
      isDeleted,
      ...rest
    } = row;
    void _fp;
    void _cp;
    changes.push({
      kind: "book",
      id: id as string,
      payload: rest,
      updated_at: toSecondsSinceRefDate(updatedAt as number),
      deleted: !!isDeleted,
      __sortKey: updatedAt as number,
    });
  }

  for (const row of highlightRows as unknown as Array<
    Record<string, unknown>
  >) {
    const updatedAt = row.updatedAt as number;
    const isDeleted = !!row.isDeleted;
    // Highlights: payload includes EVERY column (per the contract — no
    // local-only paths exist on this table).
    const { ...payload } = row;
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

  // Sort ASC by updatedAt across BOTH kinds so the iOS ChangeApplier sees
  // a stable, monotonically-increasing iteration order. Within-kind order
  // already comes from the .orderBy(asc(...)) clauses above; this final
  // sort interleaves books + highlights correctly.
  changes.sort((a, b) => a.__sortKey - b.__sortKey);
  const sanitized = changes.map(({ __sortKey: _s, ...rest }) => {
    void _s;
    return rest;
  });

  return c.json({ changes: sanitized });
});
