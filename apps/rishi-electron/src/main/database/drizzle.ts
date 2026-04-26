import { drizzle } from 'drizzle-orm/better-sqlite3'
import { getDb } from './index.js'
import * as schema from './schema.js'

/**
 * Returns a Drizzle ORM instance backed by the app's better-sqlite3 connection.
 * Call after `initDatabase()` has been invoked.
 */
export function getDrizzle() {
  return drizzle(getDb(), { schema })
}
