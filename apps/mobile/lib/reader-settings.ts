import { ReaderSettings, DEFAULT_READER_SETTINGS, ThemeName } from '@/types/book'
import { getDb } from '@/lib/db'

const SETTINGS_KEY = 'reader_settings'

let settingsTableCreated = false
function ensureSettingsTable(): void {
  if (settingsTableCreated) return
  const db = getDb()
  db.execSync(`
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    );
  `)
  settingsTableCreated = true
}

export function loadReaderSettings(): ReaderSettings {
  ensureSettingsTable()
  const db = getDb()
  const row = db.getFirstSync('SELECT value FROM settings WHERE key = ?', [SETTINGS_KEY]) as { value: string } | null
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
  const db = getDb()
  db.runSync(
    'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
    [SETTINGS_KEY, JSON.stringify(settings)]
  )
}
