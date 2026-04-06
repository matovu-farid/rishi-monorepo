# Phase 8: Desktop Sync Integration - Research

**Researched:** 2026-04-06
**Domain:** Desktop SQLite migration (integer IDs to UUIDs), TypeScript sync engine for Tauri, bidirectional sync
**Confidence:** HIGH

## Summary

The desktop Tauri app currently uses integer autoincrement IDs for books and chunk_data, managed via Diesel (Rust ORM) for backend operations and Kysely (TypeScript) for frontend queries via `tauri-plugin-sql`. The mobile app and D1 server both use UUID text primary keys with sync columns (syncVersion, isDirty, isDeleted, updatedAt). The core challenge is migrating the desktop SQLite schema to match the mobile/server schema while preserving existing user data and foreign key relationships, then implementing a sync engine in TypeScript that can be shared between desktop and mobile.

The desktop app currently has NO highlights table, NO conversations/messages tables, and NO sync infrastructure. It stores book annotations only in epub.js memory (not persisted to SQLite). The existing sync engine on mobile (`apps/mobile/lib/sync/engine.ts`) and the Worker endpoints (`workers/worker/src/routes/sync.ts`, `upload.ts`) are fully operational and require no changes -- the desktop just needs to speak the same protocol.

**Primary recommendation:** Migrate desktop SQLite via a new Diesel migration that adds UUID columns, backfills existing data, and creates missing tables (highlights, conversations, messages, sync_meta). Then implement the sync engine as a shared TypeScript package that both desktop (via `tauri-plugin-sql` + Kysely) and mobile (via Drizzle) can consume. The desktop frontend already has `tauri-plugin-sql` access via Kysely, so the sync engine can run entirely in the TypeScript layer without new Rust commands.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DSYNC-01 | Desktop SQLite schema migrated to include UUID sync identifiers | Diesel migration adds syncId TEXT column to books, creates highlights/conversations/messages/sync_meta tables. Kysely schema updated to match. |
| DSYNC-02 | Desktop app gains push/pull sync engine using shared TypeScript package | Refactor mobile sync engine into `@rishi/sync` package consumed by both desktop and mobile. Desktop calls via Kysely + tauri-plugin-sql, mobile via Drizzle. |
| DSYNC-03 | Books imported on desktop sync to mobile and vice versa | Desktop file-sync (hash + R2 upload/download) mirrors mobile file-sync.ts, using fetch API available in Tauri webview. |
| DSYNC-04 | Reading progress syncs bidirectionally between desktop and mobile | Desktop `location` field maps to mobile `currentCfi`/`currentPage`. Migration normalizes field names. LWW on updatedAt. |
| DSYNC-05 | Highlights and annotations sync bidirectionally | Desktop must persist highlights to SQLite (currently ephemeral in epub.js). New highlights table matches mobile schema. |
</phase_requirements>

## Standard Stack

### Core (Already in project)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Diesel | 2.3.4 | Rust-side SQLite migrations and ORM | Already used for desktop DB -- migrations are embedded and run on startup |
| Kysely | 0.28.x | TypeScript-side SQL queries in desktop | Already used in `apps/main/src/modules/kysley.ts` for frontend DB access |
| tauri-plugin-sql | 2.x | Bridge between Tauri webview and SQLite | Already installed, provides Database class for Kysely dialect |
| @rishi/shared | 0.1.0 | Shared schema (Drizzle) and sync types | Already used by mobile and worker |
| Drizzle ORM | 0.44.x | Mobile SQLite ORM | Already used in mobile -- shared package depends on it |

### New (Needed for this phase)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| sha256 (Web Crypto API) | N/A | File hashing for R2 dedup on desktop | Available natively in Tauri webview -- no npm package needed |
| @tauri-apps/plugin-fs | 2.x | Read book files for hashing/upload on desktop | Already installed in desktop package.json |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Shared TS sync engine | Rust sync engine | TS is faster to iterate, matches requirement "shared TypeScript package", and mobile already uses TS |
| Kysely for desktop sync | Drizzle for desktop sync | Kysely is already set up in desktop; switching to Drizzle would require migration of all existing desktop queries |

## Architecture Patterns

### Recommended Project Structure
```
packages/
  shared/src/
    schema.ts            # (existing) Drizzle schema -- source of truth for table shapes
    sync-types.ts        # (existing) Push/Pull request/response types
    sync-engine.ts       # (NEW) Platform-agnostic sync logic with DB adapter interface
    sync-adapter.ts      # (NEW) DbAdapter interface definition
    file-sync.ts         # (NEW) Platform-agnostic R2 upload/download logic with adapter
apps/
  main/src/
    modules/
      kysley.ts          # (MODIFIED) Add sync tables to Kysely schema
      sync-adapter.ts    # (NEW) Kysely-based DbAdapter implementation for desktop
      file-sync.ts       # (NEW) Desktop file hashing/upload using @tauri-apps/plugin-fs
      sync-triggers.ts   # (NEW) Desktop sync triggers (on app focus, periodic, on write)
    src-tauri/
      migrations/
        XXXX_add_sync_columns/ # (NEW) Diesel migration for schema changes
  mobile/lib/
    sync/
      engine.ts          # (MODIFIED) Use shared sync engine with Drizzle adapter
      sync-adapter.ts    # (NEW) Drizzle-based DbAdapter implementation
```

### Pattern 1: Database Adapter Interface
**What:** Abstract the sync engine's database operations behind an interface so the same logic works with Kysely (desktop) and Drizzle (mobile).
**When to use:** When the same business logic must run on two different ORM/query-builder stacks.
**Example:**
```typescript
// packages/shared/src/sync-adapter.ts
export interface SyncDbAdapter {
  getDirtyBooks(): Promise<SyncBook[]>
  getDirtyHighlights(): Promise<SyncHighlight[]>
  getDirtyConversations(): Promise<SyncConversation[]>
  getDirtyMessages(): Promise<SyncMessage[]>
  getLastSyncVersion(): Promise<number>

  applyBookConflict(id: string, data: Record<string, unknown>, syncVersion: number): Promise<void>
  applyHighlightConflict(id: string, data: Record<string, unknown>, syncVersion: number): Promise<void>
  applyConversationConflict(id: string, data: Record<string, unknown>, syncVersion: number): Promise<void>
  markBooksClean(ids: string[], syncVersion: number): Promise<void>
  markHighlightsClean(ids: string[], syncVersion: number): Promise<void>
  markConversationsClean(ids: string[], syncVersion: number): Promise<void>
  markMessagesClean(ids: string[], syncVersion: number): Promise<void>

  upsertRemoteBook(remote: Record<string, unknown>): Promise<void>
  upsertRemoteHighlight(remote: Record<string, unknown>): Promise<void>
  upsertRemoteConversation(remote: Record<string, unknown>): Promise<void>
  insertRemoteMessage(remote: Record<string, unknown>): Promise<void>
  updateLastSyncVersion(version: number): Promise<void>
}
```

### Pattern 2: Diesel Migration for Schema Evolution
**What:** Use Diesel's embedded migration system to add UUID sync columns and create new tables in the desktop SQLite database. The migration runs automatically on app startup.
**When to use:** Every schema change to the desktop's Rust-managed SQLite database.
**Example:**
```sql
-- migrations/XXXX_add_sync_tables/up.sql

-- Add sync columns to existing books table
ALTER TABLE books ADD COLUMN sync_id TEXT;
ALTER TABLE books ADD COLUMN file_hash TEXT;
ALTER TABLE books ADD COLUMN file_r2_key TEXT;
ALTER TABLE books ADD COLUMN cover_r2_key TEXT;
ALTER TABLE books ADD COLUMN format TEXT NOT NULL DEFAULT 'epub';
ALTER TABLE books ADD COLUMN current_cfi TEXT;
ALTER TABLE books ADD COLUMN current_page INTEGER;
ALTER TABLE books ADD COLUMN user_id TEXT;
ALTER TABLE books ADD COLUMN sync_version INTEGER DEFAULT 0;
ALTER TABLE books ADD COLUMN is_dirty INTEGER DEFAULT 1;
ALTER TABLE books ADD COLUMN is_deleted INTEGER DEFAULT 0;

-- Back-fill sync_id with UUIDs for existing books
-- NOTE: SQLite has no built-in UUID function. We generate via Rust after migration.

-- Create highlights table (matches mobile/D1 schema)
CREATE TABLE IF NOT EXISTS highlights (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    cfi_range TEXT NOT NULL,
    text TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT 'yellow',
    note TEXT,
    chapter TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
);

-- Create conversations table
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    title TEXT NOT NULL DEFAULT 'New conversation',
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
);

-- Create messages table
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    source_chunks TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
);

-- Create sync_meta table
CREATE TABLE IF NOT EXISTS sync_meta (
    id TEXT PRIMARY KEY NOT NULL,
    last_sync_version INTEGER DEFAULT 0,
    last_sync_at INTEGER
);
INSERT OR IGNORE INTO sync_meta (id, last_sync_version) VALUES ('default', 0);
```

### Pattern 3: Dual Primary Key Strategy (Integer ID preserved, UUID sync_id added)
**What:** Keep the existing integer `id` as primary key for desktop's internal FK relationships (chunk_data.bookId references books.id). Add a separate `sync_id` TEXT column containing the UUID used for sync. The sync engine uses `sync_id` to communicate with the server; internal desktop operations continue using the integer `id`.
**When to use:** When migrating a mature schema where changing the PK type would break too many FK references.
**Why this approach:**
- Desktop books.id is INTEGER AUTOINCREMENT and referenced by chunk_data.bookId (also INTEGER)
- Changing books.id from INTEGER to TEXT would require rebuilding the chunk_data table (SQLite has no ALTER COLUMN)
- The sync server uses UUID text IDs -- desktop needs a UUID to participate
- The dual-key approach is non-destructive: existing queries keep working, sync logic uses sync_id

### Anti-Patterns to Avoid
- **Changing the desktop books PK from INTEGER to TEXT:** SQLite does not support ALTER COLUMN. Would require CREATE-COPY-DROP-RENAME of both books AND chunk_data tables, risking data loss. Use the dual-key approach instead.
- **Sharing the exact sync engine.ts file between platforms:** Mobile uses synchronous Drizzle `.all()` / `.run()`, desktop uses async Kysely `.execute()`. The shared code must be async-compatible.
- **Running sync from Rust:** The requirement says "sync logic lives in a shared TypeScript package." Do not build sync commands in Rust.
- **Hard-coding Worker URL:** Desktop already has the Worker URL in commands.rs. Centralize it in a config/constant accessible from TypeScript.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| UUID generation | Custom UUID function | `crypto.randomUUID()` (available in Tauri webview) | Standard, matches mobile's expo-crypto randomUUID |
| File hashing | Custom SHA-256 | `crypto.subtle.digest('SHA-256', ...)` (Web Crypto API) | Available in Tauri webview, no dependency needed |
| Presigned URL auth | Custom R2 signing | Existing Worker `/api/sync/upload-url` and `/api/sync/download-url` endpoints | Already built and tested |
| SQLite migrations | Manual ALTER TABLE from TS | Diesel embedded migrations (Rust) | Already the pattern -- migrations run on app startup automatically |

**Key insight:** The mobile sync engine and Worker API are battle-tested. Desktop should consume the same API endpoints with the same protocol. The only new complexity is the schema migration and the Kysely adapter.

## Common Pitfalls

### Pitfall 1: SQLite ALTER TABLE Limitations
**What goes wrong:** Trying to change a column type, rename a column, or add a column with a non-constant default fails in SQLite.
**Why it happens:** SQLite's ALTER TABLE only supports ADD COLUMN and RENAME TABLE. No ALTER COLUMN, no DROP COLUMN (before 3.35.0).
**How to avoid:** Only use ALTER TABLE ADD COLUMN for new columns. For the sync_id backfill, add the column as nullable first, then populate in Rust code after migration, then use it as non-null in application logic.
**Warning signs:** Migration fails on first run with "near MODIFY: syntax error."

### Pitfall 2: Foreign Key bookId Mismatch Between Desktop and Server
**What goes wrong:** Desktop chunk_data.bookId is INTEGER referencing books.id (INTEGER). Server/mobile highlights.book_id is TEXT (UUID). If the sync engine sends the integer bookId to the server, it will not match.
**Why it happens:** Two different ID systems (integer local vs UUID sync).
**How to avoid:** The sync engine must always translate between local integer ID and sync_id (UUID) when preparing push payloads and processing pull responses. Maintain a lookup map: `{ [syncId: string]: localId: number }`.
**Warning signs:** Books sync but highlights/chunk_data reference wrong book IDs.

### Pitfall 3: Desktop Highlights Are Not Persisted
**What goes wrong:** Desktop epub.js highlights exist only in rendition memory. They vanish on page reload and can never sync.
**Why it happens:** Desktop never added a highlights SQLite table -- it was built before sync was a requirement.
**How to avoid:** As part of this phase, persist highlights to the new `highlights` table on desktop. Hook into epub.js annotation events to save/update/delete highlights in SQLite.
**Warning signs:** Highlights created on mobile appear on desktop after sync, but highlights created on desktop never appear on mobile.

### Pitfall 4: Reading Position Field Name Mismatch
**What goes wrong:** Desktop stores reading position in `books.location` (a string, could be epubCFI or page number). Mobile/server stores it in `books.current_cfi` (EPUB) and `books.current_page` (PDF).
**Why it happens:** Desktop schema predates the mobile sync schema design.
**How to avoid:** The migration adds `current_cfi` and `current_page` columns. Post-migration Rust code copies `location` to `current_cfi` for epub books and parses to `current_page` for pdf books. The sync engine uses the new column names.
**Warning signs:** Reading position appears as null after sync because the field name mapping was missed.

### Pitfall 5: Cover Data Format Mismatch
**What goes wrong:** Desktop stores cover as BLOB (binary) in `books.cover`. Mobile stores cover as a file path `books.cover_path`. Server stores cover in R2 with `books.cover_r2_key`.
**Why it happens:** Different architectural choices made independently.
**How to avoid:** During book push from desktop, extract the cover BLOB, save to a temp file, hash it, and upload to R2. Store the resulting `cover_r2_key` in the book's sync record. On pull, download cover from R2 and convert to BLOB for desktop storage.
**Warning signs:** Books sync but covers are missing on the other device.

### Pitfall 6: Concurrent Diesel and Kysely SQLite Access
**What goes wrong:** Both Diesel (Rust, via r2d2 pool) and Kysely (TS, via tauri-plugin-sql) access the same rishi.db file. Without WAL mode, writes from one can block the other.
**Why it happens:** Two separate connection managers to the same SQLite file.
**How to avoid:** Desktop already enables WAL mode (`PRAGMA journal_mode=WAL`) in db.rs setup. Ensure tauri-plugin-sql also uses WAL mode. WAL allows concurrent reads and serialized writes safely.
**Warning signs:** Intermittent "database is locked" errors during sync.

## Code Examples

### Desktop Kysely Schema Update (sync tables)
```typescript
// apps/main/src/modules/kysley.ts - Updated DB interface
export interface DB {
  books: {
    id: Generated<number>
    kind: string
    cover: number[]
    title: string
    author: string
    publisher: string
    filepath: string
    location: string
    cover_kind: string
    version: number
    created_at: ColumnType<Date, string | undefined, never>
    updated_at: ColumnType<Date, string | undefined, never>
    // NEW sync columns
    sync_id: string | null        // UUID for sync identification
    format: string                 // 'epub' | 'pdf'
    current_cfi: string | null     // EPUB reading position
    current_page: number | null    // PDF reading position
    file_hash: string | null
    file_r2_key: string | null
    cover_r2_key: string | null
    user_id: string | null
    sync_version: number
    is_dirty: number               // 0 or 1
    is_deleted: number             // 0 or 1
  }

  chunk_data: {
    id: number
    pageNumber: number
    bookId: number
    data: string
    created_at: ColumnType<Date, string | undefined, never>
    updated_at: ColumnType<Date, string | undefined, never>
  }

  highlights: {
    id: string                     // UUID
    book_id: string                // sync_id of the book
    user_id: string | null
    cfi_range: string
    text: string
    color: string
    note: string | null
    chapter: string | null
    created_at: number
    updated_at: number
    sync_version: number
    is_dirty: number
    is_deleted: number
  }

  conversations: {
    id: string
    book_id: string                // sync_id of the book
    user_id: string | null
    title: string
    created_at: number
    updated_at: number
    sync_version: number
    is_dirty: number
    is_deleted: number
  }

  messages: {
    id: string
    conversation_id: string
    role: string
    content: string
    source_chunks: string | null
    created_at: number
    updated_at: number
    sync_version: number
    is_dirty: number
    is_deleted: number
  }

  sync_meta: {
    id: string
    last_sync_version: number
    last_sync_at: number | null
  }
}
```

### Desktop Sync Adapter (Kysely-based)
```typescript
// apps/main/src/modules/sync-adapter.ts
import { db } from './kysley'
import type { SyncDbAdapter, SyncBook } from '@rishi/shared/sync-adapter'

export class DesktopSyncAdapter implements SyncDbAdapter {
  async getDirtyBooks(): Promise<SyncBook[]> {
    const rows = await db
      .selectFrom('books')
      .selectAll()
      .where('is_dirty', '=', 1)
      .where('sync_id', 'is not', null)
      .execute()

    // Map desktop schema to sync schema (sync_id becomes id)
    return rows.map(row => ({
      id: row.sync_id!,
      title: row.title,
      author: row.author,
      format: row.format ?? row.kind,
      currentCfi: row.current_cfi,
      currentPage: row.current_page,
      fileHash: row.file_hash,
      fileR2Key: row.file_r2_key,
      coverR2Key: row.cover_r2_key,
      createdAt: new Date(row.created_at).getTime(),
      updatedAt: new Date(row.updated_at).getTime(),
      syncVersion: row.sync_version,
      isDirty: true,
      isDeleted: row.is_deleted === 1,
    }))
  }

  // ... other adapter methods follow same pattern
}
```

### Post-Migration UUID Backfill (Rust)
```rust
// In db.rs setup_database(), after running Diesel migrations:
use uuid::Uuid;

fn backfill_sync_ids(pool: &Pool<ConnectionManager<SqliteConnection>>) -> anyhow::Result<()> {
    let mut conn = pool.get()?;

    // Find books without sync_id
    let rows: Vec<(i32,)> = diesel::sql_query(
        "SELECT id FROM books WHERE sync_id IS NULL"
    )
    .load::<(i32,)>(&mut conn)?;

    for (book_id,) in rows {
        let uuid = Uuid::new_v4().to_string();
        diesel::sql_query(
            "UPDATE books SET sync_id = $1, is_dirty = 1 WHERE id = $2"
        )
        .bind::<diesel::sql_types::Text, _>(&uuid)
        .bind::<diesel::sql_types::Integer, _>(&book_id)
        .execute(&mut conn)?;
    }

    Ok(())
}
```

## State of the Art

| Old Approach (Desktop) | Current Approach (Mobile/Server) | When Changed | Impact |
|------------------------|----------------------------------|--------------|--------|
| Integer autoincrement PK | UUID text PK | Phase 4 (mobile) | Desktop must add UUID sync_id column |
| No highlights table | Highlights in SQLite with sync | Phase 5 (mobile) | Desktop must create highlights table, persist epub.js highlights |
| No conversations table | Conversations + messages in SQLite | Phase 6 (mobile) | Desktop must create conversations/messages tables |
| `location` field for reading pos | `current_cfi` + `current_page` fields | Phase 4 (mobile) | Desktop must add/map new fields |
| Cover as BLOB in SQLite | Cover as file path + R2 key | Phase 4 (mobile) | Desktop must handle cover upload to R2 |
| Kysely for TS queries | Drizzle ORM for TS queries | Phase 4 (mobile) | Shared sync code needs adapter pattern |

## Open Questions

1. **Desktop conversations: real-time voice chat vs text-based?**
   - What we know: Desktop uses OpenAI Realtime API for voice conversations (see chat_atoms.ts, realtime.ts). Mobile uses text-based conversations with RAG.
   - What's unclear: Should desktop voice conversations sync as text transcripts to mobile? Are they the same "conversations" entity?
   - Recommendation: For v1, only sync text-based conversations. Desktop realtime voice chats are a different paradigm and should be treated separately. If desktop adds text conversation UI later, it syncs naturally.

2. **UUID backfill timing: Diesel migration or Rust post-migration?**
   - What we know: SQLite has no built-in UUID generator. Diesel migrations are pure SQL.
   - What's unclear: Whether to use a SQL workaround (hex(randomblob(16))) or post-migration Rust code.
   - Recommendation: Use `hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))` in SQL migration for UUID v4 generation. This keeps migration self-contained.

3. **Should desktop adopt Drizzle to replace Kysely?**
   - What we know: Mobile uses Drizzle, desktop uses Kysely. Both access SQLite.
   - What's unclear: Whether migrating desktop to Drizzle is worth the effort.
   - Recommendation: Keep Kysely on desktop. The adapter pattern isolates ORM differences. Migrating all existing desktop queries to Drizzle is unnecessary scope.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Vitest (desktop TS), Cargo test (desktop Rust), Jest (mobile) |
| Config file | `apps/main/vitest.config.ts`, `apps/main/src-tauri/Cargo.toml` |
| Quick run command | `cd apps/main && npx vitest run --reporter=verbose` |
| Full suite command | `cd apps/main && npx vitest run && cd src-tauri && cargo test` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DSYNC-01 | Diesel migration adds sync columns and tables | unit (Rust) | `cd apps/main/src-tauri && cargo test test_migration_sync_columns` | No -- Wave 0 |
| DSYNC-01 | Kysely schema matches migrated DB | unit (TS) | `cd apps/main && npx vitest run src/modules/kysley.test.ts` | No -- Wave 0 |
| DSYNC-02 | Shared sync engine push/pull works with adapter | unit (TS) | `cd packages/shared && npx vitest run src/sync-engine.test.ts` | No -- Wave 0 |
| DSYNC-03 | Desktop book push results in server record | integration | Manual -- requires Worker and R2 | N/A |
| DSYNC-04 | Reading position roundtrips through sync | unit (TS) | `cd apps/main && npx vitest run src/modules/sync-adapter.test.ts` | No -- Wave 0 |
| DSYNC-05 | Highlights persist to desktop SQLite | unit (TS) | `cd apps/main && npx vitest run src/modules/highlight-storage.test.ts` | No -- Wave 0 |

### Sampling Rate
- **Per task commit:** `cd apps/main && npx vitest run --reporter=verbose`
- **Per wave merge:** `cd apps/main && npx vitest run && cd src-tauri && cargo test`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `apps/main/src-tauri/migrations/XXXX_add_sync_tables/up.sql` -- Diesel migration file
- [ ] `apps/main/src-tauri/migrations/XXXX_add_sync_tables/down.sql` -- Diesel rollback
- [ ] `packages/shared/src/sync-engine.ts` -- Shared sync engine with adapter interface
- [ ] `packages/shared/src/sync-adapter.ts` -- DbAdapter interface
- [ ] `apps/main/src/modules/sync-adapter.ts` -- Desktop Kysely adapter
- [ ] `apps/main/src/modules/sync-adapter.test.ts` -- Adapter unit tests
- [ ] Vitest config may need updating to handle new test files in modules/

## Sources

### Primary (HIGH confidence)
- Desktop Tauri source code: `apps/main/src-tauri/src/` -- schema.rs, models.rs, sql.rs, db.rs, commands.rs, lib.rs
- Desktop frontend: `apps/main/src/modules/kysley.ts` -- current Kysely schema and DB interface
- Mobile sync engine: `apps/mobile/lib/sync/engine.ts` -- proven push/pull implementation
- Mobile file sync: `apps/mobile/lib/sync/file-sync.ts` -- R2 upload/download pattern
- Worker sync API: `workers/worker/src/routes/sync.ts` -- server-side push/pull endpoints
- Worker upload API: `workers/worker/src/routes/upload.ts` -- presigned URL endpoints
- Shared schema: `packages/shared/src/schema.ts` -- Drizzle table definitions
- Shared sync types: `packages/shared/src/sync-types.ts` -- Push/Pull type interfaces
- Desktop Diesel migrations: `apps/main/src-tauri/migrations/` -- existing migration structure
- Desktop Cargo.toml: uuid 1.19.0 already in dependencies

### Secondary (MEDIUM confidence)
- SQLite ALTER TABLE documentation: SQLite only supports ADD COLUMN, not ALTER COLUMN or DROP COLUMN
- Diesel embedded migrations docs: Migrations run automatically on `conn.run_pending_migrations(MIGRATIONS)`

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All libraries already in project, versions verified from Cargo.toml and package.json
- Architecture: HIGH - Adapter pattern is well-established, mobile sync engine is proven
- Pitfalls: HIGH - Identified from direct code analysis of schema mismatches and SQLite limitations
- Migration strategy: HIGH - Dual-key approach avoids destructive PK change

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable -- no external library changes expected)
