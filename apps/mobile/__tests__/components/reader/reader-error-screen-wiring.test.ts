/**
 * P0-L — each reader screen must render <ReaderErrorScreen /> (with
 * Back + Retry + cause-specific copy) when the load fails, instead of
 * the bare "Book file not available" dead end.
 *
 * Mounting the four reader screens directly is infeasible — they pull
 * in WebView, the RAG stack, every zustand store, and four different
 * platform-dependent renderers. We follow the established source-grep
 * pattern from `pdf-reader-highlight-tap.test.tsx` / `goto-page-android.test.tsx`.
 *
 * For each reader file we pin:
 *   1. The bare `Book file not available` Text dead end is gone.
 *   2. `ReaderErrorScreen` is imported.
 *   3. `<ReaderErrorScreen ... />` is rendered with `cause`, `onBack`, `onRetry` props.
 *   4. There is `cause` state (so failed-download detection works) — i.e. a
 *      `setErrorCause` or equivalent error-tracking call site exists.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const READER_FILES: Array<{ label: string; relpath: string[] }> = [
  { label: 'EPUB', relpath: ['app', 'reader', '[id].tsx'] },
  { label: 'PDF', relpath: ['app', 'reader', 'pdf', '[id].tsx'] },
  { label: 'MOBI', relpath: ['app', 'reader', 'mobi', '[id].tsx'] },
  { label: 'DJVU', relpath: ['app', 'reader', 'djvu', '[id].tsx'] },
]

const APP_ROOT = join(__dirname, '..', '..', '..')

function read(reader: (typeof READER_FILES)[number]): string {
  return readFileSync(join(APP_ROOT, ...reader.relpath), 'utf-8')
}

describe('P0-L — readers no longer render the bare "Book file not available" dead end', () => {
  for (const reader of READER_FILES) {
    it(`${reader.label}: source no longer contains the dead-end <Text>Book file not available</Text>`, () => {
      const src = read(reader)
      // The literal string should be gone — copy now lives in the shared component.
      expect(src).not.toMatch(/<Text[^>]*>\s*Book file not available\s*<\/Text>/)
    })
  }
})

describe('P0-L — readers import and render <ReaderErrorScreen />', () => {
  for (const reader of READER_FILES) {
    it(`${reader.label}: imports ReaderErrorScreen from @/components/reader/ReaderErrorScreen`, () => {
      const src = read(reader)
      expect(src).toMatch(
        /from\s+['"]@\/components\/reader\/ReaderErrorScreen['"]|from\s+['"]@\/components\/reader['"]/,
      )
      expect(src).toMatch(/ReaderErrorScreen/)
    })

    it(`${reader.label}: renders <ReaderErrorScreen ... /> with cause/onBack/onRetry`, () => {
      const src = read(reader)
      // The tag must appear with the three required props somewhere in the file.
      expect(src).toMatch(/<ReaderErrorScreen[\s\S]{0,400}cause=/)
      expect(src).toMatch(/<ReaderErrorScreen[\s\S]{0,400}onBack=/)
      expect(src).toMatch(/<ReaderErrorScreen[\s\S]{0,400}onRetry=/)
    })

    it(`${reader.label}: tracks an error cause in state (so the loader can distinguish failures)`, () => {
      const src = read(reader)
      // Either a useState for errorCause / loadError, or a direct cause variable.
      // We accept either "errorCause" or "loadError" naming.
      expect(src).toMatch(/errorCause|loadError/i)
    })

    it(`${reader.label}: sets cause='cloud-download-failed' from getBookForReading's catch branch`, () => {
      const src = read(reader)
      // The catch path of the loader must set the cause to cloud-download-failed.
      expect(src).toMatch(/['"]cloud-download-failed['"]/)
    })
  }
})
