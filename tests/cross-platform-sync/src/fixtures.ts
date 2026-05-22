import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

/** Absolute path to the EPUB fixture both specs use. */
export const FIXTURE_EPUB = path.resolve(__dirname, '..', 'fixtures', 'test-book.epub')

/**
 * The title we tag the imported book with — both specs assert against this
 * exact string. Keep it short + unique-ish so it's easy to grep through logs.
 */
export const FIXTURE_TITLE = 'E2E Cross-Platform Fixture'
