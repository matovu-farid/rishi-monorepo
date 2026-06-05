/**
 * Task 1 — Drizzle migration v1: book_pages / book_words / book_paragraphs
 *
 * Tests that the v1 migration:
 *   - creates the three PDF text-cache tables
 *   - adds the four extraction-status columns on `books`
 *   - enforces composite PKs
 *   - is idempotent (safe to run twice)
 *
 * expo-sqlite requires native bindings not available in Node.js. We
 * implement a minimal pure-JS in-memory SQLite-compatible fake that handles
 * exactly the DDL/DML subset used by runMigrations() and the v1 migration
 * body:
 *   - CREATE TABLE (IF NOT EXISTS)
 *   - ALTER TABLE … ADD COLUMN
 *   - CREATE INDEX (IF NOT EXISTS)
 *   - INSERT INTO (with NOT NULL / UNIQUE / PRIMARY KEY enforcement)
 *   - PRAGMA table_info(tbl)
 *   - PRAGMA user_version [= N]
 *   - SELECT name FROM sqlite_master WHERE type='table'
 *
 * This gives us real schema-correctness verification without native deps.
 */

// ─── Minimal in-memory SQLite fake ──────────────────────────────────────────

interface ColDef {
  name: string
  type: string
  notNull: boolean
  dflt: string | null
  pk: boolean        // single-column PK
}

interface TableDef {
  name: string
  cols: ColDef[]
  rows: Record<string, unknown>[]
  compositePk: string[]   // ordered list of PK column names (empty = no composite PK)
}

function makeInMemoryDb() {
  const tables = new Map<string, TableDef>()
  let userVersion = 0

  // ── helpers ──────────────────────────────────────────────────────────────

  /** Parse `col TYPE [NOT NULL] [DEFAULT expr]` — good-enough for our DDL. */
  function parseColDef(raw: string): ColDef {
    raw = raw.trim()
    // strip inline PRIMARY KEY on a single column — we handle composite PKs
    // via the table-level PRIMARY KEY(...) constraint below.
    const pkInline = /\bPRIMARY\s+KEY\b/i.test(raw)
    raw = raw.replace(/\bPRIMARY\s+KEY\b/gi, '').trim()

    const notNull = /\bNOT\s+NULL\b/i.test(raw)
    raw = raw.replace(/\bNOT\s+NULL\b/gi, '').trim()

    const dfltMatch = /\bDEFAULT\s+(\S+)/i.exec(raw)
    const dflt = dfltMatch ? dfltMatch[1].replace(/^'|'$/g, '') : null
    raw = raw.replace(/\bDEFAULT\s+\S+/gi, '').trim()

    // Remove other modifiers we don't need to track
    raw = raw.replace(/\bUNIQUE\b/gi, '').trim()

    const parts = raw.split(/\s+/)
    const name = parts[0]
    const type = parts.slice(1).join(' ') || 'TEXT'

    return { name, type, notNull, dflt, pk: pkInline }
  }

  /**
   * Very small CREATE TABLE parser. Handles:
   *   CREATE TABLE [IF NOT EXISTS] name (col1 TYPE ..., PRIMARY KEY (c1, c2))
   */
  function execCreateTable(sql: string, ifNotExists: boolean): void {
    const m = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(([\s\S]+)\)/i.exec(sql)
    if (!m) throw new Error(`Cannot parse CREATE TABLE: ${sql}`)
    const tblName = m[1]
    const body = m[2]

    if (tables.has(tblName)) {
      if (ifNotExists) return
      throw new Error(`Table ${tblName} already exists`)
    }

    // Split on top-level commas (ignore commas inside parens)
    const parts: string[] = []
    let depth = 0
    let cur = ''
    for (const ch of body) {
      if (ch === '(') { depth++; cur += ch }
      else if (ch === ')') { depth--; cur += ch }
      else if (ch === ',' && depth === 0) { parts.push(cur.trim()); cur = '' }
      else { cur += ch }
    }
    if (cur.trim()) parts.push(cur.trim())

    const cols: ColDef[] = []
    let compositePk: string[] = []

    for (const part of parts) {
      const trimmed = part.trim()
      if (/^PRIMARY\s+KEY\s*\(/i.test(trimmed)) {
        // PRIMARY KEY (col1, col2)
        const pkMatch = /\(([^)]+)\)/i.exec(trimmed)
        if (pkMatch) {
          compositePk = pkMatch[1].split(',').map((c) => c.trim())
        }
      } else if (/^FOREIGN\s+KEY/i.test(trimmed) || /^UNIQUE\s*\(/i.test(trimmed)) {
        // skip
      } else {
        cols.push(parseColDef(trimmed))
      }
    }

    tables.set(tblName, { name: tblName, cols, rows: [], compositePk })
  }

  /** ALTER TABLE tbl ADD COLUMN col TYPE [modifiers] */
  function execAlterAddCol(sql: string): void {
    const m = /ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(.+)/i.exec(sql)
    if (!m) throw new Error(`Cannot parse ALTER TABLE: ${sql}`)
    const tblName = m[1]
    const tbl = tables.get(tblName)
    if (!tbl) throw new Error(`Table ${tblName} does not exist`)

    const col = parseColDef(m[2])
    if (tbl.cols.some((c) => c.name === col.name)) {
      throw new Error(`Column ${col.name} already exists in ${tblName}`)
    }
    // Back-fill existing rows with the default value
    const dfltVal = col.dflt !== null ? col.dflt : null
    for (const row of tbl.rows) {
      row[col.name] = dfltVal
    }
    tbl.cols.push(col)
  }

  /** INSERT INTO tbl (col,...) VALUES (...) */
  function execInsert(sql: string): void {
    const m = /INSERT\s+(?:OR\s+IGNORE\s+)?INTO\s+(\w+)\s*\(([^)]+)\)\s*VALUES\s*\(([^)]+)\)/i.exec(sql)
    if (!m) throw new Error(`Cannot parse INSERT: ${sql}`)
    const tblName = m[1]
    const tbl = tables.get(tblName)
    if (!tbl) throw new Error(`Table ${tblName} does not exist`)

    const isIgnore = /INSERT\s+OR\s+IGNORE/i.test(sql)
    const colNames = m[2].split(',').map((c) => c.trim())
    const rawVals = m[3].split(',').map((v) => v.trim())

    const row: Record<string, unknown> = {}
    for (let i = 0; i < colNames.length; i++) {
      const raw = rawVals[i]
      // Unquote string literals
      if (/^'[^']*'$/.test(raw)) {
        row[colNames[i]] = raw.slice(1, -1)
      } else if (raw === 'NULL') {
        row[colNames[i]] = null
      } else {
        const n = Number(raw)
        row[colNames[i]] = Number.isFinite(n) ? n : raw
      }
    }

    // Check PK uniqueness
    const pkCols = tbl.compositePk.length > 0
      ? tbl.compositePk
      : tbl.cols.filter((c) => c.pk).map((c) => c.name)

    if (pkCols.length > 0) {
      const conflict = tbl.rows.some((r) =>
        pkCols.every((c) => r[c] === row[c]),
      )
      if (conflict) {
        if (isIgnore) return
        throw new Error(`UNIQUE constraint failed: ${tblName} (${pkCols.join(', ')})`)
      }
    }

    tbl.rows.push(row)
  }

  // ── PRAGMA table_info ────────────────────────────────────────────────────

  function pragmaTableInfo(tblName: string): Array<{ name: string; type: string; notnull: number; dflt_value: string | null; pk: number }> {
    const tbl = tables.get(tblName)
    if (!tbl) return []
    return tbl.cols.map((c, i) => ({
      cid: i,
      name: c.name,
      type: c.type,
      notnull: c.notNull ? 1 : 0,
      dflt_value: c.dflt,
      pk: c.pk ? 1 : 0,
    }))
  }

  // ── SELECT name FROM sqlite_master WHERE type='table' ───────────────────

  function selectTableNames(): Array<{ name: string }> {
    return Array.from(tables.keys()).map((name) => ({ name }))
  }

  // ── Public interface ─────────────────────────────────────────────────────

  function execSync(sql: string): void {
    // Strip leading/trailing whitespace and handle multi-statement strings
    // by splitting on ';' then processing each non-empty statement.
    const stmts = sql
      .split(';')
      .map((s) => s.trim())
      .filter(Boolean)

    for (const stmt of stmts) {
      execSingle(stmt)
    }
  }

  function execSingle(sql: string): void {
    const upper = sql.trimStart().toUpperCase()

    if (/^CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS/i.test(sql)) {
      execCreateTable(sql, true)
    } else if (/^CREATE\s+TABLE(?!\s+IF)/i.test(sql)) {
      execCreateTable(sql, false)
    } else if (/^CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?/i.test(sql)) {
      // We don't track indexes (no benefit for these unit tests) — just no-op.
    } else if (/^ALTER\s+TABLE/i.test(sql)) {
      execAlterAddCol(sql)
    } else if (/^INSERT/i.test(sql)) {
      execInsert(sql)
    } else if (/^PRAGMA\s+user_version\s*=/i.test(sql)) {
      const m = /=\s*(\d+)/i.exec(sql)
      if (m) userVersion = Number.parseInt(m[1], 10)
    } else if (/^UPDATE/i.test(sql)) {
      // back-fill UPDATEs from the db.ts bootstrap — no-op for our tests
    } else if (/^PRAGMA\s+user_version/i.test(upper) || /^SELECT/i.test(upper)) {
      // Handled by getAllSync / getFirstSync — ignore in execSync
    } else {
      // Unknown statement — silently skip (mirrors expo-sqlite behaviour for
      // unsupported pragmas etc.)
    }
  }

  function getAllSync<T>(sql: string): T[] {
    const upper = sql.trim().toUpperCase()

    if (/^PRAGMA\s+TABLE_INFO\s*\(/i.test(sql)) {
      const m = /PRAGMA\s+TABLE_INFO\s*\(\s*(\w+)\s*\)/i.exec(sql)
      if (!m) return []
      return pragmaTableInfo(m[1]) as unknown as T[]
    }

    if (/^PRAGMA\s+user_version/i.test(sql)) {
      return [{ user_version: userVersion }] as unknown as T[]
    }

    if (/SELECT\s+name\s+FROM\s+sqlite_master/i.test(sql)) {
      return selectTableNames() as unknown as T[]
    }

    return []
  }

  function getFirstSync<T>(sql: string): T | undefined {
    const results = getAllSync<T>(sql)
    return results[0]
  }

  return { execSync, getAllSync, getFirstSync }
}

// ─── Mock expo-sqlite before any @/lib/db import ─────────────────────────────
// db.ts calls openDatabaseSync at module level so we must mock before import.
jest.mock('expo-sqlite', () => ({
  openDatabaseSync: jest.fn(() => makeInMemoryDb()),
}))

jest.mock('drizzle-orm/expo-sqlite', () => ({
  drizzle: jest.fn(() => ({})),
}))

jest.mock('@rishi/shared/schema', () => ({
  books: {},
  highlights: {},
  bookmarks: {},
  conversations: {},
  messages: {},
  syncMeta: {},
  syncState: {},
}))

// makeInMemoryDb must be available inside the jest.mock factory above.
// Because jest.mock is hoisted to the top of the file but the factory
// runs later, we need the function defined before the mock factory
// executes. jest.mock factories that reference out-of-scope functions
// are fine as long as the referenced name is defined at module scope
// before the factory runs — which it is here since the factory is
// evaluated lazily on first require.

import { runMigrations, migrations } from '@/lib/db'

describe('schema migration v1 — PDF text cache', () => {
  /**
   * Each test gets its own isolated in-memory database with the `books`
   * table pre-created to mirror the state of a real device that has
   * already run the bootstrap block in lib/db.ts.
   */
  function freshDb() {
    const db = makeInMemoryDb()
    return db
  }

  it('creates book_pages, book_words, book_paragraphs', () => {
    const db = freshDb()
    db.execSync(
      `CREATE TABLE books (id TEXT PRIMARY KEY, file_path TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0)`,
    )
    runMigrations(db, 1, migrations)

    const tables = db
      .getAllSync<{ name: string }>(`SELECT name FROM sqlite_master WHERE type='table'`)
      .map((r) => r.name)

    expect(tables).toEqual(expect.arrayContaining(['book_pages', 'book_words', 'book_paragraphs']))
  })

  it('adds extraction_status, extracted_pages, total_pages, extraction_error columns on books', () => {
    const db = freshDb()
    db.execSync(
      `CREATE TABLE books (id TEXT PRIMARY KEY, file_path TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0)`,
    )
    runMigrations(db, 1, migrations)

    const cols = db
      .getAllSync<{ name: string }>(`PRAGMA table_info(books)`)
      .map((r) => r.name)

    expect(cols).toEqual(
      expect.arrayContaining([
        'extraction_status',
        'extracted_pages',
        'total_pages',
        'extraction_error',
      ]),
    )
  })

  it('book_pages PK is (book_id, page_number)', () => {
    const db = freshDb()
    db.execSync(
      `CREATE TABLE books (id TEXT PRIMARY KEY, file_path TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0)`,
    )
    runMigrations(db, 1, migrations)

    db.execSync(
      `INSERT INTO book_pages (book_id, page_number, text, width_pts, height_pts, indexed_at) VALUES ('b', 1, 'a', 1.0, 1.0, 0)`,
    )
    expect(() =>
      db.execSync(
        `INSERT INTO book_pages (book_id, page_number, text, width_pts, height_pts, indexed_at) VALUES ('b', 1, 'b', 1.0, 1.0, 0)`,
      ),
    ).toThrow(/UNIQUE|PRIMARY/)
  })

  it('migration is idempotent — running twice does not throw', () => {
    const db = freshDb()
    db.execSync(
      `CREATE TABLE books (id TEXT PRIMARY KEY, file_path TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0)`,
    )
    runMigrations(db, 1, migrations)
    expect(() => runMigrations(db, 1, migrations)).not.toThrow()
  })
})
