# Spike Outcomes — for downstream agents

## T-P0.1 VAD-001 → BRANCH B (DEFER)
See `.parity-v2/VAD-SPIKE.md` and `.parity-v2/VAD-001-investigation.md`.

**Impact:** T-P2.7 closed as DEFERRED. No tests authored for mobile VAD implementation in this round. Shared VAD module untouched.

## T-P0.2 Chunk-ID parity → VERDICT D (deeper investigation; provisional B: electron aligns to shared)
See `.parity-v2/CHUNK-ID-SPIKE.md`.

**The divergence is fundamental, not stylistic:**
- Electron PDF pipeline: positional `chunkId(pageNumber, bookId, index) = pageNumber*1_000_000 + bookId*10_000 + index`, numeric bookId.
- Mobile: content-addressable `chunkIdFor(bookId, text) = stringToNumberID(\`${bookId}|${text}\`).toString()`, string UUID bookId.

Same input → different IDs and different output types. Already a parked deviation per `.parity/BATCH-2A-NOTES.md` L71-97.

**Decision for this round:** Write `chunk-id-parity.test.ts` using `test.failing(...)` (vitest) or `it.skip(..., reason)` patterns so it serves as a documented regression marker. **Do NOT attempt to align the algorithms in this round** — that requires re-indexing all existing electron installs (migration of persisted vector store), which is out of scope.

**T-P5.1 acceptance criteria (updated):**
- The test exists at `packages/shared/__tests__/chunk-id-parity.test.ts` using the shared EPUB fixture at `packages/shared/src/formats/__fixtures__/test-book.epub`.
- The test uses `test.failing(...)` and includes a comment block citing the divergence + `.parity/BATCH-2A-NOTES.md` link.
- When the test starts passing (after a future alignment), the maintainer flips `test.failing` to `test` — that signals parity has been achieved.
