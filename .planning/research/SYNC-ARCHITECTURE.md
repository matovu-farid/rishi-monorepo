# Cross-Device Sync Architecture Research

**Project:** Rishi Reading App
**Researched:** 2026-04-05
**Overall confidence:** MEDIUM-HIGH

---

## Executive Summary

Rishi needs to sync books, reading progress, highlights/annotations, and AI conversation history between a Tauri desktop app (Rust/SQLite/HNSW) and a new Expo/React Native mobile app, through a Cloudflare Worker backend. The desktop app currently stores everything locally with no cloud awareness.

The recommended architecture is **offline-first with server-authoritative sync**, using Cloudflare D1 as the sync database, Cloudflare R2 for book file storage, and expo-sqlite with Drizzle ORM on mobile. Conflict resolution uses **last-write-wins (LWW) per field** for most data, with **append-only merge** for highlights and annotations. CRDTs are overkill for this use case -- reading apps have low-conflict data patterns (one user, multiple devices, rarely editing the same field simultaneously).

---

## 1. Sync Architecture Analysis

### Why NOT CRDTs

CRDTs (Yjs, Automerge, cr-sqlite) solve collaborative editing where multiple users edit the same document simultaneously. Rishi is a **single-user, multi-device** app. The conflict surface is narrow:

- **Reading progress**: Only one device is active at a time. Last-write-wins is correct.
- **Highlights**: Additive. Two devices creating highlights produces a union, not a conflict.
- **Annotations**: Text edits on annotations could conflict, but the user is unlikely to edit the same annotation on two devices before syncing.
- **AI conversations**: Append-only logs. No conflict possible.

CRDT libraries add 50-200KB of bundle size, introduce complex mental models, and require CRDT-aware storage. The complexity is not justified here.

### Why NOT Event Sourcing

Event sourcing (storing every mutation as an event) is powerful for audit trails and replay, but adds significant complexity for a reading app. The data model is simple CRUD, not a domain requiring event replay. The operational overhead of event stores, projections, and snapshots is not warranted.

### Recommended: Timestamp-Based Sync with Pull/Push

**Model: Offline-first with periodic sync**

This is what Kindle's Whispersync does at its core: each device writes locally, syncs to a central server when online, and the server resolves conflicts using timestamps.

```
[Desktop SQLite] <--push/pull--> [Cloudflare Worker API] <--push/pull--> [Mobile SQLite]
                                        |
                                   [Cloudflare D1]  (server-of-record)
                                   [Cloudflare R2]  (book files)
```

**Sync protocol:**

1. Each record has `updated_at` (client timestamp) and `sync_version` (server-assigned monotonic counter).
2. Client pushes: sends all records with `updated_at > last_sync_timestamp` to server.
3. Server receives: for each record, compares `updated_at`. If server's copy is older, update. If newer, keep server's (conflict -- server wins, return server version to client).
4. Client pulls: requests all records with `sync_version > last_known_sync_version`. Applies to local DB.
5. Client stores `last_known_sync_version` for next pull.

**Why this works for Rishi:**
- Simple to implement and debug
- Works with existing Cloudflare Worker + Hono stack
- No new infrastructure beyond D1 and R2
- Kindle, Pocket, Kobo, and Apple Books all use variations of this pattern

---

## 2. Server-Side Storage Recommendation

### Primary Database: Cloudflare D1

**Recommendation: Use Cloudflare D1 as the server-side sync database.**

| Factor | D1 | Turso | Durable Objects |
|--------|----|----|-----------------|
| Worker integration | Native binding, zero config | HTTP client, external service | Native, but per-object isolation |
| Latency | ~0.5ms from Worker | ~15-50ms (network hop) | ~0ms (co-located) |
| Cost | $5/mo Workers plan includes 25B reads | $4.99/mo, 9GB storage | $5/mo base + per-request billing |
| Max DB size | 10 GB per database | 9 GB (dev plan) | 1 GB per DO (SQLite storage) |
| SQLite compatibility | Full SQLite semantics | libSQL (SQLite superset) | Full SQLite |
| ORM support | Drizzle native | Drizzle native | Drizzle via sql.exec |
| Complexity | Low -- just a D1 binding | Medium -- external dependency | High -- per-user DO management |

**Why D1 over alternatives:**

- **Already in the Cloudflare ecosystem.** The Worker already uses Hono. D1 is a binding in wrangler.toml, not a new service to manage.
- **Drizzle ORM works natively** with both D1 (server) and expo-sqlite (mobile), meaning the same schema definitions and query patterns on both sides.
- **10 GB is more than enough.** A reading app's metadata (book records, highlights, reading positions, conversation history) is tiny. Book files go to R2, not D1. Even with 10,000 books and 100,000 highlights, you would use < 100 MB.
- **Scale-to-zero pricing.** No cost when idle. Pay only for rows read/written.

**Why NOT Turso:** Adds an external dependency and network hop. Turso's embedded replicas are designed for edge servers, not mobile clients. The offline sync beta is interesting but immature and adds vendor lock-in beyond Cloudflare.

**Why NOT Durable Objects:** DO's per-object isolation model (one SQLite per DO instance) would mean creating a DO per user. While architecturally clean, it adds operational complexity (DO lifecycle management, class migrations) for no real benefit at Rishi's scale. D1 is simpler.

**Why NOT Upstash Redis:** Redis is not a good fit for relational sync data. It works for the auth state relay but should not expand beyond that role. It lacks schema, migrations, and relational queries.

### File Storage: Cloudflare R2

**Recommendation: Store book files (EPUB/PDF) in Cloudflare R2 with presigned URL uploads.**

- Books are large binary files (1-50 MB typically). They should NOT go in D1.
- R2 is S3-compatible, zero egress fees, native Worker binding.
- **Upload flow:** Client requests presigned PUT URL from Worker -> Client uploads directly to R2 -> Worker records metadata in D1.
- **Download flow:** Client requests presigned GET URL from Worker -> Client downloads directly from R2.
- **Deduplication:** Hash the book file (SHA-256) before upload. Store the hash in D1 metadata. If another device uploads the same book, skip the upload and link to the existing R2 object. This is critical because the same EPUB will be imported on desktop and mobile.

**R2 pricing:** Free tier includes 10 GB storage, 10M reads/month, 1M writes/month. More than sufficient.

### ORM: Drizzle

**Recommendation: Use Drizzle ORM on both server (D1) and mobile (expo-sqlite).**

- Drizzle has native adapters for both Cloudflare D1 and expo-sqlite.
- ~7.4 KB gzipped -- works on edge runtimes with bundle size limits.
- Type-safe schema definitions can be shared across the monorepo.
- Drizzle Kit handles migrations for both targets.
- 900,000+ weekly npm downloads as of early 2026. Actively maintained.

---

## 3. Mobile Local Storage

### Recommendation: expo-sqlite with Drizzle ORM

**Use `expo-sqlite` (built into Expo SDK 54) paired with Drizzle ORM.**

| Library | Expo compat | Sync built-in | Bundle size | Maturity |
|---------|------------|--------------|-------------|----------|
| expo-sqlite | Native (part of SDK) | No | 0 (included) | HIGH |
| WatermelonDB | Requires config plugin | Yes (pull/push) | ~150KB | HIGH |
| op-sqlite | Requires config plugin | No | ~80KB | MEDIUM |
| PowerSync | Requires config plugin | Yes (to Postgres) | ~200KB+ | MEDIUM |
| RxDB | Works with expo-sqlite | Yes (custom) | ~300KB+ | MEDIUM |

**Why expo-sqlite:**

1. **Zero additional native dependencies.** Already in Expo SDK 54 (which the project uses). No config plugins, no native build complications.
2. **Drizzle integration is first-class.** `drizzle-orm/expo-sqlite` driver exists with live queries via `useLiveQuery` hook.
3. **Same SQL dialect as D1.** Both are SQLite. Schema definitions, migration patterns, and query logic transfer directly.
4. **Expo team actively maintains it.** Recent additions include WAL mode support, prepared statements, and the Drizzle Studio dev plugin for debugging.

**Why NOT WatermelonDB:** WatermelonDB has an opinionated sync protocol (pull/push with server-defined changes) that would work, but it forces you into its data model (Model classes, decorators, relations). Since we are building a custom sync protocol to match the desktop app's schema, WatermelonDB's abstractions become constraints rather than helpers. It also requires a config plugin for Expo.

**Why NOT PowerSync:** PowerSync syncs from Postgres/MySQL/MongoDB, not Cloudflare D1. It would require abandoning D1 for Supabase/Neon Postgres, adding unnecessary infrastructure. Great product, wrong fit.

### Mobile Schema Design

The mobile SQLite schema should mirror the D1 schema with additional sync metadata columns:

```sql
-- Books table (mobile)
CREATE TABLE books (
    id TEXT PRIMARY KEY,           -- UUID, not auto-increment (for cross-device identity)
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    author TEXT NOT NULL,
    publisher TEXT NOT NULL,
    cover_r2_key TEXT,             -- R2 object key for cover image
    file_r2_key TEXT,              -- R2 object key for book file
    file_hash TEXT,                -- SHA-256 of book file for dedup
    location TEXT NOT NULL DEFAULT '',
    cover_kind TEXT NOT NULL DEFAULT '',
    version INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    -- Sync metadata
    sync_version INTEGER DEFAULT 0,  -- Server's sync version when last pulled
    is_dirty INTEGER DEFAULT 1,      -- 1 = needs push to server
    is_deleted INTEGER DEFAULT 0     -- Soft delete for sync
);

-- Reading progress
CREATE TABLE reading_progress (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL REFERENCES books(id),
    location TEXT NOT NULL,          -- epubcfi or page number
    progress_percent REAL DEFAULT 0,
    device_id TEXT NOT NULL,         -- Which device set this
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1
);

-- Highlights and annotations
CREATE TABLE highlights (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL REFERENCES books(id),
    cfi_range TEXT NOT NULL,         -- EPUB CFI range or PDF coordinates
    highlighted_text TEXT NOT NULL,
    annotation TEXT DEFAULT '',
    color TEXT DEFAULT 'yellow',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
);

-- AI conversation history
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL REFERENCES books(id),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1
);

CREATE TABLE messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    role TEXT NOT NULL,               -- 'user' | 'assistant'
    content TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1
);
```

**Key schema changes from desktop:**

1. **UUIDs instead of auto-increment IDs.** Auto-increment IDs collide across devices. Use UUIDs (or ULIDs for sortability) generated client-side.
2. **`sync_version` and `is_dirty` columns** on every synced table. `is_dirty` marks local changes that need pushing. `sync_version` tracks the server version for pulling.
3. **Soft deletes (`is_deleted`).** Never hard-delete synced records locally. Mark as deleted, sync the deletion, then clean up after confirmation.
4. **`file_r2_key` replaces `filepath`.** Mobile does not have the same filesystem. Books reference R2 keys and are cached locally.
5. **`device_id` on reading_progress.** Allows the server to track which device last updated position.

---

## 4. Book File Sync Strategy

### Recommended: Hash-Based Dedup with R2 Storage

```
Desktop imports book.epub
  -> SHA-256 hash = abc123
  -> Check D1: does file_hash=abc123 exist?
     NO -> Upload to R2 as books/{user_id}/{hash}.epub
           Record in D1: { file_hash: abc123, file_r2_key: "books/usr_x/abc123.epub" }
     YES -> Skip upload, link to existing R2 object

Mobile syncs library
  -> Pull book metadata from D1
  -> For each book not cached locally:
     -> Download from R2 using presigned GET URL
     -> Cache in app's document directory
     -> Mark as locally available
```

**Why hash-based dedup:**
- Users will import the same EPUB on desktop and mobile. Without dedup, they would store two copies in R2.
- SHA-256 is fast and collision-resistant. A 50MB EPUB hashes in <100ms.
- The hash also serves as an integrity check on download.

**Lazy download policy:**
- Do NOT auto-download all books to mobile. Download on-demand when the user opens a book.
- Show book metadata (title, author, cover thumbnail) immediately from D1 sync.
- Cover images are small (<500KB) -- download eagerly during sync.
- Book files are large -- download lazily with progress indicator.

**Local cache management:**
- Store downloaded books in the app's document directory (persists across app updates).
- Implement LRU eviction when storage exceeds a configurable threshold (e.g., 2 GB).
- Show storage usage in settings with option to remove cached books.

---

## 5. Conflict Resolution Strategy

### Reading Progress: Last-Write-Wins (Simple)

Reading progress has the simplest conflict model. Only one device is active at a time.

```
Server stores: { book_id, location, progress_percent, updated_at, device_id }

On push:
  IF client.updated_at > server.updated_at:
    Accept client's value
  ELSE:
    Reject (return server's value to client)

On pull:
  Client always accepts server's value IF server.updated_at > local.updated_at
```

**Edge case:** User reads on desktop offline, then reads on mobile offline, then both come online. The device with the later `updated_at` wins. This is correct behavior -- the user's most recent reading position is what they want.

**Confidence: HIGH** -- This is exactly how Kindle's Whispersync works (with "sync to furthest page read" as a user-facing toggle).

### Highlights: Union Merge (Additive)

Highlights are almost always additive -- users create new highlights, rarely edit existing ones.

```
On push:
  For each highlight:
    IF new (server has no record with this ID):
      Insert on server
    IF exists and client.updated_at > server.updated_at:
      Update server (annotation text changed, color changed)
    IF is_deleted:
      Mark as deleted on server (tombstone)

On pull:
  For each server highlight not in local DB:
    Insert locally
  For each server highlight with newer updated_at:
    Update locally
```

**Conflict scenario:** User creates a highlight on desktop, edits its annotation on mobile before syncing. On next sync, the mobile edit wins (later `updated_at`). The desktop's original annotation is lost. This is acceptable because:
- It is rare (editing annotations offline on two devices)
- The user's most recent edit is preserved
- The alternative (CRDT merge of text) is wildly complex for this use case

**Confidence: HIGH** -- Standard pattern for annotation sync in reading apps.

### AI Conversations: Append-Only

AI conversations are inherently append-only. Messages are never edited.

```
On push:
  Send all messages where is_dirty = 1
  Server inserts any messages it does not already have (by ID)

On pull:
  Client receives all messages with sync_version > last_known
  Insert locally (skip if ID already exists)
```

**No conflict possible** -- messages have unique IDs and are never modified after creation. The only scenario is duplicate messages, which are deduplicated by ID.

**Confidence: HIGH** -- Append-only is the simplest sync model.

### Book Metadata: Last-Write-Wins Per Field

Book metadata (title, author, cover, etc.) rarely changes after import. When it does, LWW per field is appropriate.

**Confidence: HIGH**

---

## 6. Sync Protocol Design

### API Endpoints (Worker)

```
POST /api/sync/push
  Body: { changes: { books: [...], highlights: [...], progress: [...], messages: [...] } }
  Auth: Bearer JWT (existing requireWorkerAuth middleware)
  Response: { conflicts: [...], server_sync_version: N }

GET /api/sync/pull?since_version=N
  Auth: Bearer JWT
  Response: { changes: { books: [...], highlights: [...], progress: [...], messages: [...] }, sync_version: N }

POST /api/sync/books/upload-url
  Body: { file_hash: "abc123", file_name: "book.epub", content_type: "application/epub+zip" }
  Response: { upload_url: "https://r2...", r2_key: "books/usr_x/abc123.epub" }
  (Returns presigned PUT URL, or { exists: true, r2_key: "..." } if hash already uploaded)

POST /api/sync/books/download-url
  Body: { r2_key: "books/usr_x/abc123.epub" }
  Response: { download_url: "https://r2..." }
```

### Sync Flow (Client-Side)

```typescript
async function syncWithServer() {
  // 1. Push local changes
  const dirtyRecords = await getDirtyRecords(); // is_dirty = 1
  if (dirtyRecords.length > 0) {
    const { conflicts, server_sync_version } = await api.push(dirtyRecords);
    // Apply conflict resolutions (server wins)
    await applyConflicts(conflicts);
    // Mark pushed records as clean
    await markClean(dirtyRecords);
  }

  // 2. Pull remote changes
  const lastVersion = await getLastSyncVersion();
  const { changes, sync_version } = await api.pull(lastVersion);
  await applyRemoteChanges(changes);
  await setLastSyncVersion(sync_version);
}
```

### Sync Triggers

- **On app foreground:** Sync immediately
- **On network restore:** Sync immediately
- **Periodic:** Every 5 minutes while app is active
- **On write:** Debounced sync 2 seconds after any local write (reading progress updates)
- **Manual:** Pull-to-refresh in library view

---

## 7. Desktop App Changes Required

The desktop Tauri app currently has NO sync awareness. Adding sync requires:

### Schema Migration

1. **Add UUID primary keys.** The current `books` table uses `INTEGER PRIMARY KEY AUTOINCREMENT`. This must migrate to UUID-based IDs (or add a `uuid` column alongside the existing integer ID for backward compatibility).
2. **Add sync columns:** `sync_version`, `is_dirty`, `is_deleted`, `file_hash` on all synced tables.
3. **Add new tables:** `reading_progress`, `highlights`, `conversations`, `messages` (these do not exist yet in the desktop schema).

### Sync Engine

The desktop app needs the same push/pull sync logic as mobile. Options:
- **Rust HTTP client** (reqwest) calling the same Worker endpoints
- **TypeScript sync module** in the Tauri webview, shared with mobile via monorepo package

**Recommendation:** Implement sync logic in TypeScript as a shared package (`packages/sync`) that both desktop webview and mobile app import. This avoids duplicating sync logic in Rust and TypeScript.

### Impact Assessment

This is a significant change to the desktop app. The "Out of Scope" section in PROJECT.md says "Desktop app changes -- mobile app consumes existing Worker APIs." However, sync is inherently bidirectional. The desktop app MUST gain sync capabilities for cross-device sync to work. This should be flagged as a scope expansion.

**Alternative:** Desktop uploads books and metadata to the server (one-way push) but does not pull. Mobile pulls from server. This is simpler but means changes on mobile (new highlights, reading progress) would not sync back to desktop. This defeats the purpose.

---

## 8. How Existing Apps Handle This

### Kindle (Whispersync)
- Cloud-authoritative with LWW for reading progress
- "Sync to furthest page read" as a user toggle
- Highlights/notes sync via Amazon cloud, union merge
- Books are Amazon-hosted, no user upload needed
- Requires internet for sync (not local-first in the CRDT sense)

### Apple Books
- iCloud-based sync using CloudKit
- Reading progress syncs automatically
- Highlights and notes sync with conflict resolution via iCloud
- Book files sync via iCloud Drive
- Tight OS integration unavailable to third parties

### Pocket (Read-It-Later)
- Simple metadata sync (article URL, read/unread, tags)
- Article content cached locally for offline
- LWW for read status, union merge for tags
- Much simpler data model than a book reader

### Kobo
- Cloud-authoritative sync similar to Kindle
- Reading stats, highlights, annotations all sync
- Books purchased from Kobo store sync automatically
- Side-loaded books do NOT sync (relevant to Rishi's use case)

**Key takeaway:** All major reading apps use server-authoritative sync with LWW. None use CRDTs. The data patterns in reading apps (single user, low write frequency, additive highlights) do not require eventual consistency guarantees beyond what LWW provides.

---

## 9. Implementation Phases

### Phase 1: Server Foundation
- Add D1 database with Drizzle schema to existing Worker
- Add R2 bucket for book file storage
- Implement sync API endpoints (push, pull, upload-url, download-url)
- Add `requireWorkerAuth` to all sync endpoints (already exists)

### Phase 2: Mobile Local Storage
- Set up expo-sqlite with Drizzle ORM in mobile app
- Define schema matching D1 (with sync metadata columns)
- Implement local CRUD operations
- Build sync engine (push/pull/conflict resolution)

### Phase 3: Book File Sync
- Implement hash-based dedup
- Presigned URL upload/download flow
- Local cache management with LRU eviction
- Cover image eager sync

### Phase 4: Desktop Sync Integration
- Migrate desktop schema (add UUIDs, sync columns)
- Add shared TypeScript sync package
- Implement push/pull in desktop webview
- Test cross-device sync scenarios

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|-----------|-------|
| Sync pattern (LWW) | HIGH | Industry standard for single-user multi-device reading apps |
| Cloudflare D1 | HIGH | Native Worker integration, well-documented, appropriate scale |
| Cloudflare R2 | HIGH | S3-compatible, presigned URLs documented, zero egress |
| expo-sqlite + Drizzle | HIGH | Official Expo SDK, Drizzle has native adapter, active community |
| Conflict resolution | HIGH | Well-understood patterns for reading app data types |
| Desktop schema migration | MEDIUM | Requires careful migration from integer IDs to UUIDs |
| Shared sync package | MEDIUM | Feasible but requires careful abstraction across Tauri webview and RN |
| Drizzle on both D1 and expo-sqlite | MEDIUM | Both adapters exist but sharing schema definitions across server/client needs testing |

## Open Questions

1. **Desktop scope expansion.** Does the user accept that desktop must change for true bidirectional sync? If not, a one-way (desktop-push, mobile-pull) approach is simpler but limited.
2. **Chunk data and vectors.** Should text chunks and embeddings sync, or should mobile re-process books locally / process server-side? Syncing chunks would be large but avoid re-processing. This ties into the on-device vs server-side embedding decision.
3. **Real-time sync.** The current design is poll-based (sync on foreground, periodic). Should the app use WebSockets or Server-Sent Events for real-time push notifications when another device syncs? This adds complexity but improves UX.
4. **Existing desktop integer IDs.** Migrating from auto-increment to UUIDs on the desktop app is a breaking change. An alternative is adding a `uuid` column and using it as the sync identifier while keeping the integer `id` for local foreign keys.

## Sources

- [Expo local-first architecture guide](https://docs.expo.dev/guides/local-first/)
- [Drizzle ORM - Expo SQLite](https://orm.drizzle.team/docs/connect-expo-sqlite)
- [Drizzle ORM - Cloudflare D1](https://orm.drizzle.team/docs/connect-cloudflare-d1)
- [Cloudflare D1 limits](https://developers.cloudflare.com/d1/platform/limits/)
- [Cloudflare D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)
- [Cloudflare R2 presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)
- [Cloudflare R2 upload objects](https://developers.cloudflare.com/r2/objects/upload-objects/)
- [Cloudflare Durable Objects SQLite storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Cloudflare Workers storage options](https://developers.cloudflare.com/workers/platform/storage-options/)
- [PowerSync React Native database comparison](https://www.powersync.com/blog/react-native-database-performance-comparison)
- [WatermelonDB documentation](https://watermelondb.dev/docs)
- [Expo SQLite documentation](https://docs.expo.dev/versions/latest/sdk/sqlite/)
- [Building presigned URL uploads with Hono](https://lirantal.com/blog/cloudflare-r2-presigned-url-uploads-hono)
- [Local-first apps in 2025](https://debugg.ai/resources/local-first-apps-2025-crdts-replication-edge-storage-offline-sync)
- [Turso vs Cloudflare comparison](https://www.buildmvpfast.com/compare/turso-vs-cloudflare)
- [SQLite Renaissance 2026](https://dev.to/pockit_tools/the-sqlite-renaissance-why-the-worlds-most-deployed-database-is-taking-over-production-in-2026-3jcc)
- [TinyBase vs WatermelonDB vs RxDB](https://www.pkgpulse.com/blog/tinybase-vs-watermelondb-vs-rxdb-offline-first-2026)
