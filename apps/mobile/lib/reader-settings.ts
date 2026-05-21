import { ReaderSettings, DEFAULT_READER_SETTINGS, ThemeName } from '@/types/book'
// `lib/db` exposes the raw expo-sqlite handle as `rawDb` (and the drizzle
// wrapper as `db`). Reader settings are stored in a tiny `settings`
// key/value table that pre-dates drizzle, so we keep using the raw
// handle for execSync / runSync / getFirstSync.
import { rawDb } from '@/lib/db'

const SETTINGS_KEY = 'reader_settings'

let settingsTableCreated = false
function ensureSettingsTable(): void {
  if (settingsTableCreated) return
  rawDb.execSync(`
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    );
  `)
  settingsTableCreated = true
}

export function loadReaderSettings(): ReaderSettings {
  ensureSettingsTable()
  const row = rawDb.getFirstSync('SELECT value FROM settings WHERE key = ?', [SETTINGS_KEY]) as { value: string } | null
  if (!row) return { ...DEFAULT_READER_SETTINGS }
  try {
    const parsed = JSON.parse(row.value)
    return {
      themeName: (parsed.themeName as ThemeName) || DEFAULT_READER_SETTINGS.themeName,
      fontSize: typeof parsed.fontSize === 'number' ? parsed.fontSize : DEFAULT_READER_SETTINGS.fontSize,
      fontFamily: parsed.fontFamily === 'sans-serif' ? 'sans-serif' : DEFAULT_READER_SETTINGS.fontFamily,
    }
  } catch {
    return { ...DEFAULT_READER_SETTINGS }
  }
}

export function saveReaderSettings(settings: ReaderSettings): void {
  ensureSettingsTable()
  rawDb.runSync(
    'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
    [SETTINGS_KEY, JSON.stringify(settings)]
  )
}
