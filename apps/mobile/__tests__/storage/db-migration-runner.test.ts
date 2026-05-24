/**
 * DAT-014 (#126) — schema-migration runner for the SQLite DB.
 *
 * Until this commit, lib/db.ts ran a fixed sequence of CREATE TABLE IF NOT
 * EXISTS plus ALTER TABLE statements every module load. There was no
 * PRAGMA user_version check, so a future "drop column X" or "rename
 * table" couldn't run conditionally — the migration logic would have to
 * be hand-edited in lib/db.ts and there'd be no record of which devices
 * had already run it.
 *
 * runMigrations(db, currentVersion, migrations) is the minimal runner:
 *   - reads PRAGMA user_version
 *   - runs each pending migration in order (older->newer)
 *   - writes PRAGMA user_version = <currentVersion> at the end
 * Each migration is (db) => void. Errors propagate — better to crash
 * than persist a partially-migrated DB.
 */

// expo-sqlite ships ESM; stub before db.ts touches it.
jest.mock('expo-sqlite', () => ({
  openDatabaseSync: jest.fn(() => ({
    execSync: jest.fn(),
    getAllSync: jest.fn(() => []),
    getFirstSync: jest.fn(() => undefined),
  })),
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

import { runMigrations, type Migration } from '@/lib/db'

interface FakeDb {
  execSync: jest.Mock
  getFirstSync: jest.Mock
}

function buildFakeDb(initialUserVersion: number): FakeDb {
  let userVersion = initialUserVersion
  const execSync = jest.fn((sql: string) => {
    const m = /^PRAGMA\s+user_version\s*=\s*(\d+)/i.exec(sql)
    if (m) {
      userVersion = Number.parseInt(m[1], 10)
    }
  })
  const getFirstSync = jest.fn((sql: string) => {
    if (/^PRAGMA\s+user_version/i.test(sql)) {
      return { user_version: userVersion }
    }
    return undefined
  })
  return { execSync, getFirstSync }
}

describe('DAT-014 — runMigrations', () => {
  it('is a no-op when the DB is already at the target version', () => {
    const db = buildFakeDb(3)
    const m: Migration = { version: 1, run: jest.fn() }
    runMigrations(db as never, 3, [m])
    expect(m.run).not.toHaveBeenCalled()
    // No PRAGMA write either — already at target.
    const writes = db.execSync.mock.calls.filter((c) =>
      /^PRAGMA\s+user_version\s*=/i.test(c[0]),
    )
    expect(writes).toHaveLength(0)
  })

  it('runs every migration whose version is greater than the stored user_version', () => {
    const db = buildFakeDb(0)
    const order: number[] = []
    const migrations: Migration[] = [
      { version: 1, run: () => order.push(1) },
      { version: 2, run: () => order.push(2) },
      { version: 3, run: () => order.push(3) },
    ]
    runMigrations(db as never, 3, migrations)
    expect(order).toEqual([1, 2, 3])
    // user_version is bumped to the target after all migrations succeed.
    expect(db.execSync).toHaveBeenCalledWith('PRAGMA user_version = 3')
  })

  it('skips migrations that are not greater than the stored version', () => {
    const db = buildFakeDb(2)
    const order: number[] = []
    const migrations: Migration[] = [
      { version: 1, run: () => order.push(1) },
      { version: 2, run: () => order.push(2) },
      { version: 3, run: () => order.push(3) },
      { version: 4, run: () => order.push(4) },
    ]
    runMigrations(db as never, 4, migrations)
    expect(order).toEqual([3, 4])
    expect(db.execSync).toHaveBeenCalledWith('PRAGMA user_version = 4')
  })

  it('runs migrations in ascending version order regardless of input order', () => {
    const db = buildFakeDb(0)
    const order: number[] = []
    const migrations: Migration[] = [
      { version: 3, run: () => order.push(3) },
      { version: 1, run: () => order.push(1) },
      { version: 2, run: () => order.push(2) },
    ]
    runMigrations(db as never, 3, migrations)
    expect(order).toEqual([1, 2, 3])
  })

  it('propagates errors from a failed migration (no partial-state masking)', () => {
    const db = buildFakeDb(0)
    const migrations: Migration[] = [
      { version: 1, run: () => undefined },
      {
        version: 2,
        run: () => {
          throw new Error('migration v2 failed')
        },
      },
      { version: 3, run: jest.fn() },
    ]
    expect(() => runMigrations(db as never, 3, migrations)).toThrow(
      /migration v2 failed/,
    )
    // The third migration must NOT have run.
    expect(migrations[2].run).not.toHaveBeenCalled()
    // user_version must NOT have been bumped — DB is now in a partially
    // migrated state; next launch will re-attempt from where we stopped.
    expect(db.execSync).not.toHaveBeenCalledWith('PRAGMA user_version = 3')
  })

  it('rejects a target version older than the stored user_version (downgrade is unsafe)', () => {
    const db = buildFakeDb(5)
    expect(() => runMigrations(db as never, 3, [])).toThrow(/downgrade/i)
  })

  it('rejects a target version that does not match the highest provided migration', () => {
    const db = buildFakeDb(0)
    // Caller asked to migrate to v3 but only provided up to v2 — that's
    // a programming error; we MUST refuse rather than silently mark v3
    // as reached.
    const migrations: Migration[] = [
      { version: 1, run: jest.fn() },
      { version: 2, run: jest.fn() },
    ]
    expect(() => runMigrations(db as never, 3, migrations)).toThrow(/missing migration/i)
  })
})
