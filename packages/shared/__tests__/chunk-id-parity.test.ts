/**
 * T-P5.1 — DRY-005 chunk-ID cross-platform parity test.
 *
 * Source documents:
 *   - `.parity-v2/SPEC.md` §3.7 (DRY-005 — Chunk-ID Cross-Platform Parity Test)
 *   - `.parity-v2/CHUNK-ID-SPIKE.md`
 *   - `.parity-v2/SPIKE-OUTCOMES.md` (Verdict D — write as `test.fails(...)`)
 *   - `.parity/BATCH-2A-NOTES.md` L71-97 (parked deviation note)
 *
 * Current divergence (per the spike):
 *   • Electron PDF pipeline (packages/shared/src/indexing/index-program.ts:81):
 *       chunkId(pageNumber, bookId, index) = pageNumber*1_000_000 + bookId*10_000 + index
 *     — positional, numeric `bookId`, returns `number`.
 *   • Mobile (apps/mobile/lib/rag/chunker.ts:72-74):
 *       chunkIdFor(bookId, text) = stringToNumberID(`${bookId}|${text}`).toString()
 *     — content-addressable, string (UUID) `bookId`, returns `string`.
 *
 * Same input → different IDs AND different output types. Aligning the algorithms
 * requires re-indexing all existing electron installs (migration of persisted
 * vector store) and is OUT OF SCOPE for this round.
 *
 * This test is authored as `test.fails(...)` so it serves as a documented
 * regression marker. When a future change brings the two paths into agreement,
 * the maintainer flips `test.fails` → `test` (or `it.failing` → `it`) and
 * the parity guarantee is established. Until then, the failing assertion is
 * the expected steady state — and a passing test would itself be a regression
 * (vitest fails `test.fails` blocks that unexpectedly pass).
 *
 * NOTE on imports: we replicate the two algorithms inline. The mobile chunker
 * lives at `apps/mobile/lib/rag/chunker.ts` and pulls in `expo-file-system`
 * and other react-native-only modules, which the shared vitest config cannot
 * resolve. The replicated algorithms are byte-for-byte copies of the canonical
 * sites cited above — if either site drifts, the assertion drifts with it and
 * this comment block must be updated.
 */
import { describe, test, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { stringToNumberID } from '../src/lib/stringToNumberID'

// ── Electron-side chunk-ID algorithm (verbatim copy of
//    `packages/shared/src/indexing/index-program.ts:81`) ─────────────────────
const electronChunkId = (
  pageNumber: number,
  bookId: number,
  index: number,
): number => pageNumber * 1_000_000 + bookId * 10_000 + index

// ── Mobile-side chunk-ID algorithm (verbatim copy of
//    `apps/mobile/lib/rag/chunker.ts:72-74`) ────────────────────────────────
function mobileChunkIdFor(bookId: string, chunkText: string): string {
  return stringToNumberID(`${bookId}|${chunkText}`).toString()
}

// Fixture: a deterministic 2-page sample. Each "page" has 2 paragraphs.
// This mirrors what the indexer.extract() port would yield per page.
interface FixturePage {
  pageNumber: number
  paragraphs: string[]
}

const TWO_PAGE_FIXTURE: FixturePage[] = [
  {
    pageNumber: 1,
    paragraphs: [
      'In the beginning the universe was created. This has made a lot of people very angry and been widely regarded as a bad move.',
      'The Hitchhikers Guide to the Galaxy has a few things to say on the subject of towels.',
    ],
  },
  {
    pageNumber: 2,
    paragraphs: [
      'Space is big. Really big. You just wont believe how vastly hugely mindbogglingly big it is.',
      'I mean you may think it is a long way down the road to the chemist but that is just peanuts to space.',
    ],
  },
]

// ── Sanity: the shared EPUB fixture is present (the spec requires it) ──────
test('shared EPUB fixture is present', () => {
  const fixturePath = resolve(
    __dirname,
    '..',
    'src',
    'formats',
    '__fixtures__',
    'test-book.epub',
  )
  const bytes = readFileSync(fixturePath)
  expect(bytes.byteLength).toBeGreaterThan(0)
})

describe('chunk-ID cross-platform parity (DRY-005)', () => {
  // The two paths take different `bookId` types (number vs string). To make
  // the comparison meaningful we pick a `bookId` representable in both:
  // numeric 42 on the electron side, "42" on the mobile side. Even with that
  // accommodation, the algorithms produce different IDs — which is the whole
  // point of this regression marker.
  const ELECTRON_BOOK_ID = 42
  const MOBILE_BOOK_ID = '42'

  test.fails(
    'same fixture → same chunk IDs across electron and mobile (currently DIVERGES, see header)',
    () => {
      const electronIds: Array<string> = []
      const mobileIds: Array<string> = []

      for (const page of TWO_PAGE_FIXTURE) {
        page.paragraphs.forEach((paragraph, index) => {
          // Electron: positional. Stringify so the type asymmetry (number vs
          // string) doesn't itself defeat the equality check — the divergence
          // we want to catch is the VALUE divergence.
          electronIds.push(
            electronChunkId(page.pageNumber, ELECTRON_BOOK_ID, index).toString(),
          )
          // Mobile: content-addressable.
          mobileIds.push(mobileChunkIdFor(MOBILE_BOOK_ID, paragraph))
        })
      }

      expect(electronIds).toEqual(mobileIds)
    },
  )

  // Additional cross-check: even the OUTPUT TYPES diverge. Documented for
  // the future alignment PR — once both paths return the same type, this
  // expectation becomes a free trivial pass.
  test.fails(
    'electron and mobile chunk-ID functions return the same JS type',
    () => {
      const e = electronChunkId(1, ELECTRON_BOOK_ID, 0)
      const m = mobileChunkIdFor(MOBILE_BOOK_ID, 'any text')
      expect(typeof e).toBe(typeof m)
    },
  )
})
