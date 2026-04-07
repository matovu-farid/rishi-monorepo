# Phase 04: Sync Infrastructure - Research

**Researched:** 2026-04-06
**Domain:** Offline-first sync (Cloudflare D1/R2, Drizzle ORM, expo-sqlite, presigned URLs)
**Confidence:** HIGH

## Summary

Phase 04 builds the sync backbone: Cloudflare D1 for metadata sync, Cloudflare R2 for book file storage, a push/pull sync API on the existing Hono Worker, and a mobile sync engine in the Expo app. The architecture is offline-first with server-authoritative conflict resolution (LWW per field for metadata/progress, union merge for highlights, append-only for conversations).

The critical technical validation is confirmed: **Drizzle ORM schema definitions are fully shareable between D1 and expo-sqlite.** Both use `drizzle-orm/sqlite-core` for table definitions (`sqliteTable`, `text`, `int`, `real`). The only difference is the driver initialization -- `drizzle(env.DB)` for D1 vs `drizzle(expo)` for expo-sqlite. A shared `packages/shared/schema.ts` file can define all tables once, imported by both the Worker and mobile app. Migrations are generated separately per target (`driver: 'd1-http'` vs `driver: 'expo'`).

For R2 presigned URLs, the `aws4fetch` library is the correct choice for Cloudflare Workers (the AWS SDK v3 does not work in the Workers runtime). The Worker generates signed PUT/GET URLs using `AwsClient.sign()` with `signQuery: true`, and clients upload/download directly to/from R2 without proxying through the Worker. This is the standard pattern for large file transfers (books are 1-50 MB).

**Primary recommendation:** Build a shared Drizzle schema package, add D1 + R2 bindings to the existing Worker, implement push/pull sync endpoints, and add a sync engine to the mobile app that triggers on foreground, on write (debounced), and every 5 minutes.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SYNC-01 | Cloudflare D1 schema for sync metadata | Drizzle ORM + sqlite-core schema shared between D1 and expo-sqlite; D1 binding in wrangler.jsonc; migration via `drizzle-kit generate` + `drizzle-kit migrate` |
| SYNC-02 | R2 configured for book file storage with hash-based dedup | R2 bucket binding in wrangler.jsonc; SHA-256 hash stored in D1; check hash before upload to skip duplicates |
| SYNC-03 | Worker push/pull sync API endpoints authenticated by JWT | Hono routes under `/api/sync/*` using existing `requireWorkerAuth` middleware; D1 binding via `drizzle(env.DB)` |
| SYNC-04 | Mobile syncs on foreground, on write, periodically (5 min) | AppState listener for foreground; `setInterval` for periodic; debounced trigger after local writes |
| SYNC-05 | Book files upload to R2 via presigned URLs on import | `aws4fetch` AwsClient in Worker generates signed PUT URLs; mobile uploads directly to R2 |
| SYNC-06 | Book files download from R2 on-demand (lazy download) | Worker generates signed GET URLs; mobile downloads when user opens a book not yet cached locally |
| SYNC-07 | Sync works offline-first -- all local ops succeed without network | expo-sqlite is the source of truth for local ops; sync engine wraps network calls in try/catch; dirty flags track unpushed changes |
</phase_requirements>

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| drizzle-orm | 0.45.2 | Type-safe ORM for both D1 and expo-sqlite | Same `sqlite-core` schema shared across server and mobile; native adapters for both targets |
| drizzle-kit | 0.31.10 | Schema migration generation | Generates SQL migrations for D1 (`driver: 'd1-http'`) and Expo (`driver: 'expo'`) separately |
| aws4fetch | 1.0.20 | R2 presigned URL generation in Workers | Uses Web APIs compatible with Workers runtime; AWS SDK v3 does NOT work in Workers |
| expo-sqlite | ~16.0.10 (SDK 54) | Mobile SQLite database | Already in the project; Drizzle has first-class adapter via `drizzle-orm/expo-sqlite` |
| hono | 4.10.6+ | Worker HTTP framework | Already in the project; D1 binding accessed via `c.env.DB` in route handlers |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| expo-crypto | ~15.0.x | SHA-256 file hashing on mobile | Hash book files before upload for dedup check |
| expo-file-system | ~19.0.21 | File read/write for upload/download | Already in project; read book bytes for upload, write downloaded files |
| babel-plugin-inline-import | latest | Import .sql migration files in Expo | Required by Drizzle's Expo migration system |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| aws4fetch | @aws-sdk/client-s3 + @aws-sdk/s3-request-presigner | AWS SDK v3 requires Node.js APIs unavailable in Workers runtime. Do NOT use. |
| Drizzle ORM | Raw SQL on both sides | Loses type safety and schema sharing. Not worth it. |
| Presigned URLs | Worker-proxied upload/download | Worker becomes a bottleneck for large files (1-50MB books). Presigned URLs let clients talk to R2 directly. |

**Installation (Worker):**
```bash
cd workers/worker
npm install drizzle-orm aws4fetch
npm install -D drizzle-kit
```

**Installation (Mobile):**
```bash
cd apps/mobile
npx expo install expo-crypto
npm install drizzle-orm
npm install -D drizzle-kit babel-plugin-inline-import
```

**Installation (Shared package):**
```bash
mkdir -p packages/shared
cd packages/shared
npm init -y
npm install drizzle-orm
```

## Architecture Patterns

### Recommended Project Structure
```
packages/
  shared/
    src/
      schema.ts          # Drizzle schema (sqliteTable definitions) -- shared
      sync-types.ts      # Push/pull request/response types -- shared
workers/
  worker/
    src/
      index.ts           # Existing Hono app
      routes/
        sync.ts          # POST /api/sync/push, GET /api/sync/pull
        upload.ts         # POST /api/sync/upload-url, POST /api/sync/download-url
      db/
        drizzle.ts        # drizzle(env.DB) factory
    drizzle/
      migrations/         # D1 migrations (generated by drizzle-kit)
    drizzle.config.ts     # dialect: 'sqlite', driver: 'd1-http'
apps/
  mobile/
    lib/
      db.ts              # Existing -- migrate to Drizzle
      sync/
        engine.ts         # Push/pull sync logic
        triggers.ts       # Foreground, periodic, on-write triggers
        file-sync.ts      # R2 upload/download via presigned URLs
    db/
      schema.ts           # Re-exports from packages/shared
    drizzle/
      migrations/         # Expo migrations (generated by drizzle-kit)
    drizzle.config.ts     # dialect: 'sqlite', driver: 'expo'
```

### Pattern 1: Shared Drizzle Schema
**What:** Define all table schemas once in `packages/shared/src/schema.ts` using `drizzle-orm/sqlite-core`. Both the Worker and mobile app import from this package.
**When to use:** Always -- this is the foundation of the sync architecture.
**Example:**
```typescript
// packages/shared/src/schema.ts
import { sqliteTable, text, integer, real } from 'drizzle-orm/sqlite-core';

export const books = sqliteTable('books', {
  id: text('id').primaryKey(),              // UUID, client-generated
  title: text('title').notNull(),
  author: text('author').notNull().default('Unknown'),
  format: text('format').notNull().default('epub'),
  fileHash: text('file_hash'),              // SHA-256 for R2 dedup
  fileR2Key: text('file_r2_key'),           // R2 object key
  coverR2Key: text('cover_r2_key'),         // R2 cover image key
  filePath: text('file_path'),              // Local path (mobile only, not synced)
  coverPath: text('cover_path'),            // Local cover path (mobile only)
  currentCfi: text('current_cfi'),          // EPUB position
  currentPage: integer('current_page'),     // PDF position
  createdAt: integer('created_at', { mode: 'timestamp_ms' }).notNull(),
  updatedAt: integer('updated_at', { mode: 'timestamp_ms' }).notNull(),
  syncVersion: integer('sync_version').default(0),
  isDirty: integer('is_dirty', { mode: 'boolean' }).default(true),
  isDeleted: integer('is_deleted', { mode: 'boolean' }).default(false),
});

// Source: https://orm.drizzle.team/docs/column-types/sqlite
```

### Pattern 2: Push/Pull Sync Protocol
**What:** Client pushes dirty records, server resolves conflicts and returns a new sync version. Client pulls all changes since its last known sync version.
**When to use:** Every sync cycle (foreground, periodic, on-write).
**Example:**
```typescript
// apps/mobile/lib/sync/engine.ts
import { eq, gt } from 'drizzle-orm';
import { books } from '@shared/schema';
import { apiClient } from '../api';

export async function sync(db: DrizzleDB) {
  try {
    // 1. Push dirty records
    const dirtyBooks = await db.select().from(books).where(eq(books.isDirty, true));
    if (dirtyBooks.length > 0) {
      const res = await apiClient('/api/sync/push', {
        method: 'POST',
        body: JSON.stringify({ changes: { books: dirtyBooks } }),
      });
      const { conflicts, syncVersion } = await res.json();
      // Apply conflict resolutions (server wins)
      for (const conflict of conflicts) {
        await db.update(books).set(conflict).where(eq(books.id, conflict.id));
      }
      // Mark as clean
      for (const book of dirtyBooks) {
        await db.update(books).set({ isDirty: false }).where(eq(books.id, book.id));
      }
    }

    // 2. Pull remote changes
    const lastVersion = await getLastSyncVersion(db);
    const res = await apiClient(`/api/sync/pull?since_version=${lastVersion}`);
    const { changes, syncVersion } = await res.json();
    // Upsert remote changes into local DB
    for (const book of changes.books) {
      await db.insert(books).values(book)
        .onConflictDoUpdate({ target: books.id, set: book });
    }
    await setLastSyncVersion(db, syncVersion);
  } catch (error) {
    // Offline -- silently fail, will retry on next trigger
    console.warn('Sync failed (offline?):', error);
  }
}
```

### Pattern 3: Presigned URL File Transfer
**What:** Worker generates a signed PUT/GET URL for R2; mobile uploads/downloads directly to R2 without proxying through the Worker.
**When to use:** Book file upload on import, book file download on first open.
**Example:**
```typescript
// workers/worker/src/routes/upload.ts
import { AwsClient } from 'aws4fetch';

app.post('/api/sync/upload-url', requireWorkerAuth, async (c) => {
  const { fileHash, contentType } = await c.req.json();
  const userId = c.get('userId');

  // Check if file already exists (dedup)
  const existing = await db.select()
    .from(books)
    .where(eq(books.fileHash, fileHash))
    .limit(1);
  if (existing.length > 0) {
    return c.json({ exists: true, r2Key: existing[0].fileR2Key });
  }

  const r2Key = `books/${userId}/${fileHash}`;
  const aws = new AwsClient({
    accessKeyId: c.env.R2_ACCESS_KEY_ID,
    secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
    service: 's3',
    region: 'auto',
  });

  const bucketUrl = `https://${c.env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com/${c.env.R2_BUCKET_NAME}/${r2Key}`;
  const signed = await aws.sign(bucketUrl, {
    method: 'PUT',
    aws: { signQuery: true },
  });

  return c.json({
    uploadUrl: signed.url.toString(),
    r2Key,
    expiresIn: 3600,
  });
});
```

### Pattern 4: Sync Triggers
**What:** Automatically trigger sync on app foreground, after local writes (debounced), and periodically.
**When to use:** Set up once in the app root.
**Example:**
```typescript
// apps/mobile/lib/sync/triggers.ts
import { AppState } from 'react-native';
import { sync } from './engine';

let syncInterval: ReturnType<typeof setInterval> | null = null;
let writeDebounce: ReturnType<typeof setTimeout> | null = null;

export function startSyncTriggers(db: DrizzleDB) {
  // On foreground
  AppState.addEventListener('change', (state) => {
    if (state === 'active') sync(db);
  });

  // Periodic (every 5 minutes)
  syncInterval = setInterval(() => sync(db), 5 * 60 * 1000);

  // Initial sync
  sync(db);
}

export function triggerSyncOnWrite(db: DrizzleDB) {
  if (writeDebounce) clearTimeout(writeDebounce);
  writeDebounce = setTimeout(() => sync(db), 2000);
}
```

### Anti-Patterns to Avoid
- **Proxying book files through the Worker:** Books are 1-50MB. Streaming through the Worker wastes CPU time and hits the 128MB memory limit. Always use presigned URLs for direct R2 transfer.
- **Hard deletes in synced tables:** Never `DELETE FROM books WHERE id = ?`. Always soft-delete with `is_deleted = 1` and sync the deletion. Clean up tombstones after confirmation.
- **Auto-increment IDs for synced records:** The mobile app already uses UUIDs (confirmed in `file-import.ts`). The D1 schema must also use TEXT primary keys, never INTEGER AUTOINCREMENT.
- **Signing Content-Type in presigned URLs:** When using `aws4fetch` with `signQuery: true`, do NOT include Content-Type in signed headers. Browser/mobile uploads will fail because the client sends unsigned headers that R2 rejects.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| ORM / query builder | Raw SQL strings | Drizzle ORM | Type safety, schema sharing, migration generation |
| R2 presigned URL signing | Manual AWS Sig v4 implementation | aws4fetch | Correct implementation of Sig v4 for Workers; 1 line vs 100+ |
| SHA-256 hashing (mobile) | Custom hash function | expo-crypto `digestStringAsync` | Uses native crypto APIs; handles large files |
| SQL migrations | Manual ALTER TABLE scripts | drizzle-kit generate | Tracks schema changes, generates proper migration SQL |
| Sync conflict resolution | Custom merge logic | LWW with `updated_at` comparison | Simple, proven pattern (Kindle, Kobo, Apple Books all use it) |

**Key insight:** The sync protocol itself is simple (push dirty, pull since version N, LWW for conflicts). The complexity is in the plumbing -- schema sharing, presigned URLs, migration management, dirty tracking. Use Drizzle and aws4fetch to handle the plumbing; focus implementation effort on the sync engine logic.

## Common Pitfalls

### Pitfall 1: Forgetting `nodejs_compat` Flag
**What goes wrong:** Worker crashes with `Error: No such module` when importing `aws4fetch` or `crypto`.
**Why it happens:** aws4fetch and crypto.subtle need the `nodejs_compat` compatibility flag in wrangler.jsonc.
**How to avoid:** Add `"nodejs_compat"` to the `compatibility_flags` array in `wrangler.jsonc`. The existing config has `"nodejs_als"` but NOT `"nodejs_compat"`.
**Warning signs:** Build succeeds but runtime errors on first request.

### Pitfall 2: Missing R2 CORS Configuration
**What goes wrong:** Mobile app gets CORS errors when uploading/downloading directly to R2 via presigned URLs.
**Why it happens:** R2 buckets do not allow cross-origin requests by default. The presigned URL gives permission for the operation, but CORS headers are separate.
**How to avoid:** Configure CORS rules on the R2 bucket via the Cloudflare dashboard or API. Allow origins for the mobile app (or `*` if using presigned URLs with short expiry).
**Warning signs:** curl uploads work but mobile uploads fail with network error.

### Pitfall 3: Clock Skew in LWW
**What goes wrong:** A device with a wrong clock always wins or loses conflict resolution.
**Why it happens:** `updated_at` is set by the client. If the client's clock is ahead, its changes always win.
**How to avoid:** Use server-assigned `sync_version` (monotonic counter) for ordering pulls, not client timestamps. For conflict resolution during push, accept the client's claim but log discrepancies. In practice, clock skew is rare for mobile devices (NTP sync).
**Warning signs:** One device's changes consistently overwrite the other's.

### Pitfall 4: Migration Divergence Between D1 and Expo
**What goes wrong:** D1 schema and mobile schema drift apart because migrations are generated separately.
**Why it happens:** Developers modify one drizzle.config but forget the other.
**How to avoid:** Both configs import from the SAME schema file (`packages/shared/src/schema.ts`). When schema changes, run `drizzle-kit generate` for BOTH targets. Add a CI check or script that verifies both migration sets are in sync.
**Warning signs:** Sync push/pull fails with column mismatch errors.

### Pitfall 5: Expo Drizzle Migration Setup
**What goes wrong:** Migrations fail silently or SQL files are not bundled.
**Why it happens:** Expo's bundler (Metro) does not inline `.sql` files by default.
**How to avoid:** Install `babel-plugin-inline-import`, add `['inline-import', { extensions: ['.sql'] }]` to `babel.config.js`, and add `'sql'` to `metro.config.js` `resolver.sourceExts`.
**Warning signs:** `useMigrations` returns error about missing migration files.

### Pitfall 6: Large File Upload Timeout
**What goes wrong:** Book file upload via presigned URL fails for files over ~10MB on slow connections.
**Why it happens:** Default fetch timeout or mobile network interruption.
**How to avoid:** Use chunked/resumable upload for large files, or at minimum set a generous timeout. For MVP, single PUT with 60s timeout is acceptable for most books (1-20MB). Add retry with exponential backoff.
**Warning signs:** Upload succeeds on WiFi but fails on cellular.

## Code Examples

### D1 Database Initialization in Worker
```typescript
// workers/worker/src/db/drizzle.ts
import { drizzle } from 'drizzle-orm/d1';
import * as schema from '@shared/schema';

export function createDb(d1: D1Database) {
  return drizzle(d1, { schema });
}

// In route handler:
const db = createDb(c.env.DB);
const allBooks = await db.select().from(schema.books);
```

### Expo SQLite + Drizzle Initialization on Mobile
```typescript
// apps/mobile/lib/db.ts (migrated to Drizzle)
import { drizzle } from 'drizzle-orm/expo-sqlite';
import { openDatabaseSync } from 'expo-sqlite';
import * as schema from '@shared/schema';

const expo = openDatabaseSync('rishi.db', { enableChangeListener: true });
export const db = drizzle(expo, { schema });

// In a component:
import { useLiveQuery } from 'drizzle-orm/expo-sqlite';
import { db } from '@/lib/db';
import { books } from '@shared/schema';

const { data } = useLiveQuery(db.select().from(books));
```

### Drizzle Config for D1 (Worker)
```typescript
// workers/worker/drizzle.config.ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: 'sqlite',
  driver: 'd1-http',
  schema: '../../packages/shared/src/schema.ts',
  out: './drizzle/migrations',
  dbCredentials: {
    accountId: process.env.CLOUDFLARE_ACCOUNT_ID!,
    databaseId: process.env.CLOUDFLARE_DATABASE_ID!,
    token: process.env.CLOUDFLARE_D1_TOKEN!,
  },
});
```

### Drizzle Config for Expo (Mobile)
```typescript
// apps/mobile/drizzle.config.ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: 'sqlite',
  driver: 'expo',
  schema: '../../packages/shared/src/schema.ts',
  out: './drizzle',
});
```

### SHA-256 File Hashing on Mobile
```typescript
// apps/mobile/lib/sync/file-sync.ts
import * as Crypto from 'expo-crypto';
import { File } from 'expo-file-system';

export async function hashBookFile(filePath: string): Promise<string> {
  const file = new File(filePath);
  const content = file.text();  // Read as string
  return Crypto.digestStringAsync(
    Crypto.CryptoDigestAlgorithm.SHA256,
    content
  );
}
```

### Wrangler Configuration with D1 + R2 Bindings
```jsonc
// workers/worker/wrangler.jsonc (additions)
{
  "compatibility_flags": ["nodejs_als", "nodejs_compat"],
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "rishi-sync",
      "database_id": "<create-via-wrangler>",
      "migrations_dir": "drizzle/migrations"
    }
  ],
  "r2_buckets": [
    {
      "binding": "BOOK_STORAGE",
      "bucket_name": "rishi-books"
    }
  ]
}
```

### Worker Bindings TypeScript Interface
```typescript
// Updated CloudflareBindings interface
interface CloudflareBindings {
  // Existing
  DEEPGRAM_KEY: string;
  OPENAI_API_KEY: string;
  CLERK_SECRET_KEY: string;
  CLERK_PUBLISHABLE_KEY: string;
  UPSTASH_REDIS_REST_URL: string;
  UPSTASH_REDIS_REST_TOKEN: string;
  JWT_SECRET: string;
  // New for sync
  DB: D1Database;
  BOOK_STORAGE: R2Bucket;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  CLOUDFLARE_ACCOUNT_ID: string;
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| WatermelonDB for offline-first | expo-sqlite + Drizzle ORM | 2025 (Drizzle expo adapter) | No extra native deps; schema sharing with D1 |
| AWS SDK v3 for R2 | aws4fetch | Ongoing (Workers limitation) | AWS SDK requires Node APIs absent in Workers |
| Raw SQL in expo-sqlite | Drizzle ORM typed queries | 2024-2025 | Type-safe queries, schema as code, migration generation |
| Integer auto-increment IDs | UUID text primary keys | Standard for sync | No collision across devices |

**Deprecated/outdated:**
- `expo-sqlite/legacy` API: Use `openDatabaseSync` (synchronous), not the old async API
- `@nozbe/watermelondb`: Still works but adds unnecessary abstraction when building custom sync

## Open Questions

1. **expo-crypto SHA-256 for binary files**
   - What we know: `digestStringAsync` works for strings. For binary file hashing, we may need to read the file as base64 first.
   - What's unclear: Performance of hashing a 50MB file on mobile. May need to stream.
   - Recommendation: Test with a real 50MB file. If too slow, hash in chunks or use native crypto module.

2. **Existing mobile schema migration**
   - What we know: The current `books` table uses raw SQL with `id TEXT PRIMARY KEY`. It has columns: id, title, author, cover_path, file_path, format, current_cfi, current_page, created_at.
   - What's unclear: Best approach to migrate existing data to the Drizzle-managed schema with new sync columns.
   - Recommendation: Add sync columns via migration (ALTER TABLE ADD COLUMN for `updated_at`, `sync_version`, `is_dirty`, `is_deleted`, `file_hash`, `file_r2_key`, `cover_r2_key`). Set `is_dirty = 1` for all existing records so they push on first sync.

3. **R2 CORS configuration method**
   - What we know: R2 needs CORS rules for direct mobile uploads via presigned URLs.
   - What's unclear: Whether to configure via Cloudflare dashboard, API, or lifecycle rules.
   - Recommendation: Use the Cloudflare API to set CORS rules on the bucket during initial setup. Document the curl command.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Manual + integration tests via wrangler dev |
| Config file | none -- see Wave 0 |
| Quick run command | `cd workers/worker && npx wrangler dev` (then curl endpoints) |
| Full suite command | Manual E2E: import book on mobile -> verify sync -> check D1/R2 |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SYNC-01 | D1 schema created and queryable | integration | `npx wrangler d1 execute rishi-sync --command "SELECT * FROM books LIMIT 1"` | N/A (CLI) |
| SYNC-02 | R2 bucket accepts uploads via presigned URL | integration | curl PUT to presigned URL | N/A (manual) |
| SYNC-03 | Push/pull endpoints return correct data | integration | curl POST /api/sync/push, GET /api/sync/pull | N/A (manual) |
| SYNC-04 | Mobile syncs on foreground/write/periodic | smoke | Manual: toggle foreground, insert book, wait 5 min | manual-only |
| SYNC-05 | Book uploads to R2 on import | e2e | Import book on mobile, verify R2 object exists | manual-only |
| SYNC-06 | Book downloads from R2 on demand | e2e | Open synced book on second device | manual-only |
| SYNC-07 | Offline local ops succeed | smoke | Airplane mode -> import book -> verify in local DB | manual-only |

### Sampling Rate
- **Per task commit:** `cd workers/worker && npx wrangler dev` + curl tests
- **Per wave merge:** Full push/pull cycle test with mobile app
- **Phase gate:** Complete import-sync-download cycle works end to end

### Wave 0 Gaps
- [ ] `packages/shared/` -- new package for shared Drizzle schema
- [ ] `workers/worker/drizzle.config.ts` -- D1 migration config
- [ ] `apps/mobile/drizzle.config.ts` -- Expo migration config
- [ ] `apps/mobile/babel.config.js` -- add `babel-plugin-inline-import` for .sql files
- [ ] `apps/mobile/metro.config.js` -- add 'sql' to source extensions
- [ ] D1 database creation: `npx wrangler d1 create rishi-sync`
- [ ] R2 bucket creation: `npx wrangler r2 bucket create rishi-books`
- [ ] R2 API token creation for presigned URLs (Cloudflare dashboard)

## Sources

### Primary (HIGH confidence)
- [Drizzle ORM - Expo SQLite](https://orm.drizzle.team/docs/connect-expo-sqlite) - driver setup, useLiveQuery, useMigrations
- [Drizzle ORM - Cloudflare D1](https://orm.drizzle.team/docs/connect-cloudflare-d1) - D1 driver setup, binding pattern
- [Drizzle ORM - D1 Getting Started](https://orm.drizzle.team/docs/get-started/d1-new) - full setup guide, schema definition, migration commands
- [Drizzle ORM - Expo Getting Started](https://orm.drizzle.team/docs/get-started/expo-new) - confirmed `sqlite-core` imports shared with D1
- [Cloudflare R2 Presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/) - presigned URL generation, limitations, expiry
- [Cloudflare R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/) - direct R2 binding operations
- [Cloudflare R2 aws4fetch example](https://developers.cloudflare.com/r2/examples/aws/aws4fetch/) - official example for Workers

### Secondary (MEDIUM confidence)
- [Hono + R2 Presigned URL Guide](https://lirantal.com/blog/cloudflare-r2-presigned-url-uploads-hono) - complete Hono implementation with R2 credentials
- [R2 Presigned URL Gotchas](https://ishan.page/blog/cloudflare-r2-workers-presigned/) - Content-Type signing bug, CORS issues
- [Expo local-first architecture guide](https://docs.expo.dev/guides/local-first/) - expo-sqlite patterns

### Tertiary (LOW confidence)
- [Drizzle monorepo schema sharing discussion](https://github.com/drizzle-team/drizzle-orm/discussions/2447) - community approaches (no official monorepo guide)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Drizzle ORM, aws4fetch, expo-sqlite are all verified with official docs; versions confirmed via npm registry
- Architecture: HIGH - Push/pull LWW sync is the industry standard for single-user multi-device (Kindle, Kobo, Apple Books); prior SYNC-ARCHITECTURE.md research is thorough
- Schema sharing: HIGH - Confirmed both D1 and expo-sqlite use `drizzle-orm/sqlite-core` for schema definitions; same `sqliteTable`, `text`, `int` functions
- Presigned URLs: HIGH - aws4fetch pattern verified against official Cloudflare docs and multiple blog posts with working code
- Pitfalls: MEDIUM - Clock skew and file hashing performance are theoretical concerns that need runtime validation

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable domain, 30 days)
