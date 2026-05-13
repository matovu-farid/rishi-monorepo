import type Database from 'better-sqlite3'

/**
 * Idempotent repair pass run at DB-open time.
 *
 * Fixes books rows that were imported under an earlier code path which
 * dispatched `.azw3` files through `getMobiData` and persisted them with
 * `kind = 'mobi'`. The renderer routes to `MobiView` for `kind = 'mobi'`,
 * which can't render KF8 properly, so affected books show as blank.
 *
 * Looks at `filepath` rather than file content — cheap and runs every boot,
 * so no version gate is needed. Returns the number of rows updated so callers
 * can log the action.
 */
export function repairBookKinds(db: Database.Database): number {
  const stmt = db.prepare(
    "UPDATE books SET kind = 'azw3' WHERE kind = 'mobi' AND LOWER(filepath) LIKE '%.azw3'"
  )
  const info = stmt.run()
  return info.changes
}
