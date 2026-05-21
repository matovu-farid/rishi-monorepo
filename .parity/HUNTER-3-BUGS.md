# Hunter 3 — Mobile parity bug hunt (book-import, RAG, formats, storage)

Domain: `apps/mobile/lib/{book-import,rag,bookmarks,...}`,
`packages/shared/src/{formats,book-import,indexing,lib,types}`.

Method: read suspect modules, write a failing test for each candidate
bug, then fix until green. One commit per bug.

Result: **7 bugs fixed**.

---

## H3-01 — embedBook silently writes corrupt vectors when embedder returns fewer rows than texts

- **Symptom:** Book imported, looks fine, but RAG search misses content. Some chunks have NULL vectors in sqlite-vec; later searches throw "wrong number of bindings" with no actionable error.
- **File:line:** `apps/mobile/lib/rag/pipeline.ts:47-56`
- **Root cause:** `embedBook` passed `embeddings[j]` straight to `insertChunkWithVector` without verifying the array had a value at index `j`. When `embedTextsOnServer` or `embedBatch` returns 2 vectors for 3 texts (server truncation, partial failure), the third chunk gets `undefined`, `JSON.stringify(undefined)` returns `undefined`, and sqlite rejects the bind.
- **Failing test added:** `apps/mobile/__tests__/rag-pipeline.test.ts` — "skips chunks whose embedding is undefined (server returned fewer than requested)".
- **Fix commit:** `34b0f4e01031392916f54458ba75d36ff5515220`

## H3-02 — EPUB chunker drops chapters when spine hrefs start with `/`

- **Symptom:** Sigil-built or Smashwords EPUBs imported successfully but produced zero RAG chunks; chat couldn't ground in the book content.
- **File:line:** `apps/mobile/lib/rag/chunker.ts:128` (pre-fix)
- **Root cause:** `fullPath = opfDir + href` ignored absolute-style hrefs that some publishers emit (`/OEBPS/ch1.xhtml`). The resulting `OEBPS//OEBPS/...` path missed every JSZip lookup, and the chunker silently emitted nothing. The shared `epub-cover.ts` already handled this; the chunker had drifted.
- **Failing test added:** `apps/mobile/__tests__/rag/chunker-epub.test.ts` — "returns chunks for an EPUB whose manifest hrefs are absolute (start with /)".
- **Fix commit:** `d0f6aa0d0fba016749db0b041dd15360743b1201`

## H3-03 — Book imports through the shared service never trigger a sync push

- **Symptom:** Import a book on one device, switch to another immediately — the book is missing on the second device for up to 5 minutes (or until the first device gets backgrounded).
- **File:line:** `apps/mobile/lib/book-import/adapters.ts:128-156` (DbPort.saveBook), `189-193` (DbPort.updateBookCover), `360-367` (CoverPort default updateBookCover).
- **Root cause:** All three writers set `isDirty: true` but never called `triggerSyncOnWrite()`. The legacy `lib/book-storage.insertBook` path DID call it; the divergence between import paths meant freshly imported books waited for the next periodic-sync window or AppState change to push.
- **Failing test added:** `apps/mobile/__tests__/book-import/file-import.test.ts` — "triggers a sync push after the book row is inserted".
- **Fix commit:** `0051629ea998b6170ad3da14a9e10385d12c83b6`

## H3-04 — EPUB cover extractor's branch C ignored items where media-type is listed first

- **Symptom:** Books from Calibre and several other editors imported with a blank cover even though the OPF clearly listed an image cover.
- **File:line:** `packages/shared/src/formats/epub-cover.ts:101-111` (pre-fix)
- **Root cause:** Branch C (id-contains-"cover" heuristic) used two positional regexes that both required `media-type` to appear AFTER `id` and `href`. The OPF spec is attribute-order agnostic; Calibre emits `media-type` first, which made these books fall through all three branches and return null.
- **Failing test added:** `packages/shared/src/formats/epub-cover.test.ts` — "matches manifest items where media-type appears BEFORE id and href".
- **Fix commit:** `a8e250858a54b65797c13995ce20fb60f0eaa20c`

## H3-05 — Chunker manifest reader required `id` before `href`

- **Symptom:** Calibre / Sigil books imported without errors but produced zero RAG chunks (RAG chat couldn't cite the book).
- **File:line:** `apps/mobile/lib/rag/chunker.ts:103-107` (pre-fix)
- **Root cause:** Same problem class as H3-04 but in the chunker. `itemRegex = /<item\s+[^>]*id="([^"]+)"[^>]*href="([^"]+)"[^>]*/g` required `id` to come BEFORE `href`. For OPFs with the other order, the manifest map ended up empty and every spine `idref` lookup returned undefined.
- **Failing test added:** `apps/mobile/__tests__/rag/chunker-epub.test.ts` — "returns chunks when manifest items have href BEFORE id".
- **Fix commit:** `e14aacf002d4a3d7e59451c174ddf3fa8fdf2e0a`

## H3-06 — Cover extractor couldn't resolve hrefs with `../` segments

- **Symptom:** KF8-converted / certain Sigil-templated EPUBs imported with no cover; users saw the default placeholder in the library grid.
- **File:line:** `packages/shared/src/formats/epub-cover.ts:115-123` (pre-fix)
- **Root cause:** Resolution joined `opfDir + coverHref` and tried both that and the bare `coverHref`. Neither path normalizes `../`, so `OEBPS/../images/cover.png` never matched the actual zip entry `images/cover.png`.
- **Failing test added:** `packages/shared/src/formats/epub-cover.test.ts` — "handles cover href with a parent ../ segment relative to the OPF dir".
- **Fix commit:** `af165c109cf569c5ce8e43193df82da32d8f1f17`

## H3-07 — Chunker couldn't resolve spine hrefs with `../` segments

- **Symptom:** Same class as H3-06 but for chapters. KF8 / Sigil templates that placed `Text/` at the zip root and referenced `../Text/ch1.xhtml` from the OPF emitted zero chunks.
- **File:line:** `apps/mobile/lib/rag/chunker.ts:128-134` (pre-fix)
- **Root cause:** Direct `opfDir + href` join; JSZip doesn't normalize `..` segments. The fix mirrors H3-06 with a small `normalizeZipPath` helper.
- **Failing test added:** `apps/mobile/__tests__/rag/chunker-epub.test.ts` — "returns chunks for an EPUB with parent ../ segments in spine hrefs".
- **Fix commit:** `99880f218a7749c373c0d774ef53235b37000cc2`

---

## Verification

- `pnpm -C packages/shared test` — **482 / 482 passed** (all my changes + the existing test suite).
- `npx jest` in `apps/mobile` — **525 / 528 passed**. The 3 failures (`vector.test.ts` × 1, `guardrails.test.ts` × 2, `highlights/undo-snackbar.test.tsx` × 1 sub-case) all reproduce on the pre-Hunter-3 baseline and are unrelated to this domain (vector test asserts on `execSync` but code uses `runSync`; guardrails is realtime/voice-chat; undo-snackbar is a Hunter-2 test that depends on an H2-02 fix in `useUndoSnackbar.ts`).
- `pnpm -C apps/rishi-electron typecheck` — clean.

## Stop reason

7 bugs fixed inside ~1h25m of focused review. Three of them (H3-02, H3-05, H3-07) and one of the cover-side (H3-06) follow the same "OPF/zip path is more permissive than this code assumes" pattern, which suggests the EPUB parsing paths drifted between electron and mobile and warrant a future shared-helper refactor. The two attribute-order bugs (H3-04, H3-05) point to the same underlying pitfall — positional regexes against XML — that would benefit from a single shared `parseManifestItems` helper instead of duplicated regex scanning.

The remaining ports of the audit (PDF text extractor host wiring, DJVU OCR error path, MOBI HUFF/CDIC support) are intentionally out-of-scope: they need WebView-side fixtures or unsupported-format work that the audit explicitly parks.
