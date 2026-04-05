# Project Research Summary

**Project:** Rishi Mobile App
**Domain:** Mobile reading app (Expo/React Native) with desktop feature parity
**Researched:** 2026-04-05
**Confidence:** MEDIUM-HIGH

## Executive Summary

Rishi Mobile is a reading app that must render EPUB and PDF files, run on-device semantic search (RAG), sync data across desktop and mobile, authenticate via Clerk, and support TTS/STT -- all within an Expo/React Native shell. Research across four domains confirms this is achievable with mature, well-documented libraries. The critical architectural insight is that the desktop app's epub.js rendering engine has a direct React Native equivalent (@epubjs-react-native/core), which means the position format (ePubCFI), annotation model, and theme system carry over unchanged. This eliminates the hardest cross-platform problem -- format translation -- before it starts.

The recommended approach is offline-first with server-authoritative sync. Mobile stores everything in expo-sqlite (with Drizzle ORM), syncs to Cloudflare D1 via timestamp-based push/pull, and stores book files in Cloudflare R2 with hash-based deduplication. On-device embeddings use react-native-executorch with the same all-MiniLM-L6-v2 model as the desktop app, ensuring vector compatibility. Vector search uses expo-sqlite's bundled sqlite-vec extension (brute-force KNN, adequate for the expected scale of under 50K vectors). Auth is straightforward: Clerk's Expo SDK handles sessions natively, and the existing Worker token exchange endpoint works without modification.

The primary risks are: (1) the app requires Expo development builds from day one (react-native-pdf and react-native-executorch both need native modules, ruling out Expo Go), (2) the desktop app must gain sync capabilities for true bidirectional sync, which is currently listed as out of scope, and (3) the embedding model (~80MB) needs a thoughtful download/bundling strategy to avoid a poor first-launch experience.

## Key Decisions Resolved

| Decision | Resolution | Rationale |
|----------|-----------|-----------|
| EPUB rendering engine | @epubjs-react-native/core (WebView + epub.js) | Same engine as desktop; ePubCFI positions are directly portable; industry standard approach (Kindle, Apple Books all use WebView) |
| PDF rendering engine | react-native-pdf | Battle-tested native renderer; config plugin for Expo dev builds; upgrade path to react-native-pdf-jsi later |
| On-device vs server embeddings | Hybrid: on-device primary, server fallback for bulk | react-native-executorch + all-MiniLM-L6-v2 works on-device; same model as desktop ensures vector compatibility |
| Vector storage | expo-sqlite + sqlite-vec (brute-force KNN) | First-party Expo support; brute-force is fast enough for under 50K vectors; no extra native modules |
| Sync architecture | Timestamp-based LWW push/pull, NOT CRDTs | Single-user multi-device has low conflict surface; CRDTs add unjustified complexity; matches Kindle/Kobo patterns |
| Server database | Cloudflare D1 (sync DB) + R2 (book files) | Already in Cloudflare ecosystem; Drizzle ORM works on both D1 and expo-sqlite; zero new infrastructure |
| Mobile local DB | expo-sqlite + Drizzle ORM | Part of Expo SDK (zero extra native deps); Drizzle shares schema definitions with D1 |
| Auth approach | @clerk/expo with token exchange to Worker JWT | Clerk Expo SDK handles sessions natively; existing /api/auth/exchange endpoint works as-is |
| Audio (TTS) | expo-audio with useAudioPlayer | Newer dedicated audio API; plays MP3 from Worker TTS endpoint |
| Audio (STT) | expo-audio record-then-send (MVP); @siteed/expo-audio-studio for streaming (later) | Record-then-send has zero extra deps; streaming upgrade is available when needed |
| Build on existing scaffold | Yes | apps/mobile/ is a clean Expo 54 scaffold with NativeWind, expo-router 6, New Architecture enabled |

## Recommended Stack

| Concern | Library | Why This One |
|---------|---------|-------------|
| EPUB rendering | @epubjs-react-native/core + /expo-file-system | Same epub.js engine as desktop; CFI positions portable |
| PDF rendering | react-native-pdf + react-native-blob-util | Battle-tested; native PDFKit/AndroidPdfViewer |
| On-device embeddings | react-native-executorch (all-MiniLM-L6-v2) | Software Mansion maintained; same model as desktop |
| Vector search | expo-sqlite + sqlite-vec extension | First-party Expo; brute-force adequate at scale |
| Local database | expo-sqlite + Drizzle ORM | Zero extra native deps; schema shared with D1 |
| Server database | Cloudflare D1 + Drizzle ORM | Native Worker binding; same Drizzle schema |
| File storage | Cloudflare R2 (presigned URLs) | Zero egress; hash-based dedup |
| Auth | @clerk/expo + expo-secure-store | Native session management; encrypted token storage |
| Audio | expo-audio | Playback (useAudioPlayer) and recording (useAudioRecorder) |
| File import | expo-document-picker + expo-file-system (SDK 54) | MIME filtering; SAF URI support on Android |
| WebView (EPUB dep) | react-native-webview | Required by @epubjs-react-native |
| Gestures (EPUB dep) | react-native-gesture-handler | Required by @epubjs-react-native |

## Architecture Overview

```
+------------------+        +------------------------+        +------------------+
|  Mobile App      |        |  Cloudflare Worker     |        |  Desktop App     |
|  (Expo/RN)       |        |  (Hono)                |        |  (Tauri)         |
|                  |        |                        |        |                  |
|  expo-sqlite     |<-push->|  D1 (sync database)    |<-push->|  SQLite (Diesel) |
|  + Drizzle       |  pull  |  + Drizzle             |  pull  |  + shared sync   |
|                  |        |                        |        |    package       |
|  sqlite-vec      |        |  R2 (book files)       |        |                  |
|  (vectors)       |        |  presigned URLs        |        |                  |
|                  |        |                        |        |                  |
|  ExecuTorch      |        |  Workers AI            |        |  embed_anything  |
|  (MiniLM-L6-v2)  |        |  (bulk fallback)       |        |  (MiniLM-L6-v2)  |
|                  |        |                        |        |                  |
|  @clerk/expo     |------->|  Clerk middleware       |        |  Clerk web flow  |
|                  |  JWT   |  /api/auth/exchange     |        |                  |
|                  |        |  /api/audio/speech      |        |                  |
|                  |        |  /api/llm/*             |        |                  |
+------------------+        +------------------------+        +------------------+
```

**Key patterns:**
- **Offline-first:** All reading, search, and annotation works without network. Sync happens opportunistically.
- **Same embedding model everywhere:** all-MiniLM-L6-v2 on desktop (embed_anything) and mobile (ExecuTorch). Vectors are interchangeable.
- **Same position format:** ePubCFI strings on both platforms (both use epub.js). No format translation needed for reading progress or highlight sync.
- **Server-authoritative sync:** D1 is the source of truth. LWW per field for metadata/progress, union merge for highlights, append-only for conversations.
- **Lazy book download:** Sync metadata eagerly, download book files on-demand with LRU cache eviction.

## Risk Register

Ordered by severity (critical first):

| # | Risk | Severity | Likelihood | Mitigation |
|---|------|----------|-----------|------------|
| 1 | **Desktop app must change for bidirectional sync** -- PROJECT.md lists desktop changes as out of scope, but sync requires schema migration (UUID PKs, sync columns) and a sync engine on desktop | CRITICAL | CERTAIN | Accept scope expansion or settle for one-way desktop-push/mobile-pull. Recommend building sync logic as a shared TS package in `packages/sync`. |
| 2 | **No Expo Go development** -- react-native-pdf and react-native-executorch require native modules. Development uses custom dev client only. | HIGH | CERTAIN | Set up EAS Build and expo-dev-client in Phase 1. This is a workflow change, not a blocker. |
| 3 | **Embedding model download on first launch** -- all-MiniLM-L6-v2 is ~80MB. Bundling inflates binary; downloading requires graceful UX. | HIGH | LIKELY | Download on first use with progress indicator. Allow reading before embedding completes. ExecuTorch supports both bundled and downloaded models. |
| 4 | **WebView memory on low-end Android** -- epub.js in WebView + embedding model could exhaust RAM on 2-3GB devices | MEDIUM | POSSIBLE | Test on low-end devices early. Unload WebView when leaving reader. Load embedding model only during embedding, unload after. |
| 5 | **@epubjs-react-native maintenance** -- last release Jan 2025. If a blocking bug is found, response may be slow. | MEDIUM | POSSIBLE | Fork the repo preemptively. Codebase is small (WebView bridge + epub.js). |
| 6 | **Mixing embedding models breaks search** -- if server fallback uses bge-small instead of MiniLM, vectors are incompatible | MEDIUM | POSSIBLE | Either run MiniLM on server too, or keep server vectors in a separate index. Never mix. |
| 7 | **Desktop integer-to-UUID migration** -- existing auto-increment IDs will collide across devices | MEDIUM | CERTAIN | Add a `uuid` column alongside existing integer ID for backward compatibility. Use UUID as sync identifier. |
| 8 | **PDF annotation creation not supported** -- react-native-pdf is read-only for annotations | LOW | CERTAIN | Defer PDF annotations to v2. Focus on EPUB annotations first (fully supported). |
| 9 | **Android SAF URI edge cases** -- some file providers (Google Drive, OneDrive) may produce problematic URIs | LOW | POSSIBLE | Always copy picked files to app document directory. Never read from SAF URIs directly. |

## Open Questions

These require user input or implementation-time testing:

1. **Desktop sync scope.** Does the user accept that desktop must gain sync capabilities? If not, sync is one-way only (desktop pushes, mobile pulls, mobile changes do not return to desktop). This fundamentally changes the product value.

2. **Embedding model delivery.** Bundle the ~80MB model in the app binary (larger download, instant availability) or download on first use (smaller app, delayed availability)? Recommend download-on-first-use with a clear loading state.

3. **Deepgram STT endpoint.** No transcription endpoint exists on the Worker. Need to build one. For MVP, a simple POST endpoint that forwards audio to Deepgram REST API is sufficient. For real-time streaming later, the Worker would mint temporary Deepgram keys for direct WebSocket connections.

4. **Real-time sync notifications.** Current design is poll-based (sync on foreground, every 5 min, on write). Should the app use WebSockets/SSE for instant cross-device updates? Adds complexity but improves UX when switching devices. Recommend deferring to post-MVP.

5. **TTS response format.** Need to verify the Worker's /api/audio/speech returns MP3 (OpenAI TTS default). expo-audio plays MP3 natively, so this should work, but needs confirmation.

6. **react-native-rag vs manual pipeline.** Software Mansion's react-native-rag provides a turnkey RAG pipeline but adds OP-SQLite alongside expo-sqlite. Evaluate whether it supports custom metadata (book_id, page_number) before committing. If not, use the individual components.

## Phasing Implications

### Phase 1: Foundation and Auth
**Rationale:** Everything depends on the build infrastructure (dev client, not Expo Go) and auth. Get these right first.
**Delivers:** Working Expo dev build, Clerk auth flow, Worker JWT exchange, protected route structure.
**Key work:** Set up EAS Build, add @clerk/expo, restructure routes into (auth) and (tabs) groups, verify Worker CORS with mobile requests.
**Research needed:** None -- standard Clerk Expo setup, well-documented.

### Phase 2: EPUB Reader
**Rationale:** EPUB is the primary format and the core reading experience. Validates the WebView rendering approach early.
**Delivers:** EPUB rendering with pagination, themes, position tracking, basic navigation.
**Key work:** Integrate @epubjs-react-native/core, implement file import via expo-document-picker, store books in app document directory.
**Avoids pitfall:** Test WebView memory on low-end devices during this phase, not later.
**Research needed:** None -- @epubjs-react-native has good docs and examples.

### Phase 3: PDF Reader and File Management
**Rationale:** PDF is the secondary format. Depends on the dev build from Phase 1 and file management patterns from Phase 2.
**Delivers:** PDF rendering, unified library view for both formats, file storage structure.
**Key work:** Add react-native-pdf, build library UI showing both EPUB and PDF books.
**Research needed:** None -- react-native-pdf is well-established.

### Phase 4: Sync Infrastructure
**Rationale:** Sync is the highest-complexity feature and touches everything. Build it before features that depend on it (highlights sync, progress sync).
**Delivers:** D1 schema, R2 book storage, sync API endpoints, mobile sync engine, book file dedup.
**Key work:** D1 + Drizzle schema, R2 presigned URL flow, push/pull sync protocol, expo-sqlite schema with sync metadata, conflict resolution logic.
**Avoids pitfall:** Build the shared sync package early so desktop integration is not an afterthought.
**Research needed:** YES -- test Drizzle schema sharing between D1 and expo-sqlite. Validate presigned URL upload flow end-to-end.

### Phase 5: Reading Progress and Highlights
**Rationale:** Depends on both the reader (Phase 2/3) and sync (Phase 4). This is where cross-device value becomes real.
**Delivers:** Reading position sync (ePubCFI for EPUB, page number for PDF), highlight creation and sync, annotation editing.
**Key work:** Hook @epubjs-react-native annotation API into sync engine, implement LWW for progress and union merge for highlights.
**Research needed:** None -- ePubCFI sync is well-understood from BOOK-RENDERING research.

### Phase 6: On-Device RAG
**Rationale:** Depends on books being stored locally (Phase 2/3). Most complex ML integration; isolate it so failures do not block reading.
**Delivers:** Text chunking, on-device embedding, vector storage, semantic search, AI Q&A about book content.
**Key work:** react-native-executorch setup, text extraction from EPUB/PDF, chunking pipeline, sqlite-vec storage, query embedding, LLM call via Worker.
**Avoids pitfall:** Download model on first use with progress UI, not bundled. Unload model after embedding completes.
**Research needed:** YES -- validate ExecuTorch embedding performance on real devices. Test react-native-rag vs manual pipeline. Measure memory pressure.

### Phase 7: Audio (TTS and STT)
**Rationale:** Audio is additive, not foundational. Build after core reading and AI features work.
**Delivers:** Text-to-speech playback from Worker endpoint, speech-to-text for voice queries.
**Key work:** expo-audio for TTS playback, expo-audio recorder for STT, new Worker endpoint for Deepgram transcription.
**Research needed:** Minimal -- verify TTS response format, test expo-audio playback pipeline.

### Phase 8: Desktop Sync Integration
**Rationale:** Requires the sync infrastructure (Phase 4) to be stable. Desktop changes are a scope expansion that should be deferred until mobile is functional.
**Delivers:** Bidirectional sync between desktop and mobile.
**Key work:** Desktop schema migration (add UUIDs, sync columns), shared TypeScript sync package, push/pull in desktop webview.
**Research needed:** YES -- desktop SQLite migration strategy (integer IDs to UUIDs) needs careful planning.

### Phase Ordering Rationale

- **Auth before everything** because every Worker call requires a JWT.
- **EPUB before PDF** because it is the primary format and validates the core rendering approach.
- **Sync before highlights/progress** because highlights without sync are a local-only feature with no cross-device value.
- **RAG isolated in its own phase** because it has the most unknowns (model download, memory, performance) and should not block the reading experience.
- **Desktop sync last** because it is a scope expansion that only matters once mobile is fully functional.

### Research Flags

Phases needing deeper research during planning:
- **Phase 4 (Sync Infrastructure):** Drizzle schema sharing between D1 and expo-sqlite needs hands-on validation. Presigned URL flow needs end-to-end testing.
- **Phase 6 (On-Device RAG):** ExecuTorch performance on real devices is estimated, not measured. Memory pressure during embedding needs testing. react-native-rag maturity is uncertain.
- **Phase 8 (Desktop Sync):** Integer-to-UUID migration on an existing SQLite database with foreign keys is a delicate operation.

Phases with standard patterns (skip research):
- **Phase 1 (Auth):** Clerk Expo SDK is well-documented with official quickstart guides.
- **Phase 2 (EPUB Reader):** @epubjs-react-native has clear API docs and examples.
- **Phase 3 (PDF Reader):** react-native-pdf is mature and widely used.
- **Phase 7 (Audio):** expo-audio is standard Expo SDK with straightforward API.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Book Rendering | MEDIUM-HIGH | @epubjs-react-native is proven but not heavily starred (240); react-native-pdf is solid |
| On-Device ML | MEDIUM-HIGH | react-native-executorch is well-maintained; performance estimates are extrapolated, not measured |
| Sync Architecture | HIGH | LWW sync is industry standard; D1/R2/Drizzle are all well-documented |
| Auth | HIGH | Clerk Expo SDK is official, well-documented, and the existing Worker endpoint works |
| Audio | MEDIUM | expo-audio is newer; TTS playback is straightforward; STT streaming needs more validation |
| Desktop Integration | MEDIUM | Feasible but represents scope expansion with migration risk |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **Embedding performance on real devices.** All estimates are extrapolated from benchmarks. Need to measure actual per-chunk latency and memory usage on target devices during Phase 6 planning.
- **Drizzle schema sharing.** Both D1 and expo-sqlite adapters exist, but sharing schema definitions across server and client in a monorepo has not been validated hands-on.
- **react-native-rag maturity.** Announced July 2025, ~v0.2.0. May not support custom metadata needed for book-specific retrieval. Evaluate early in Phase 6.
- **Desktop sync scope.** The PROJECT.md says desktop changes are out of scope. Bidirectional sync requires desktop changes. This needs a decision before Phase 4 planning.
- **Deepgram Worker endpoint.** Does not exist yet. Must be built for STT. Low complexity but needs to be scoped into Phase 7.

## Sources

Aggregated from research documents. See individual files for full source lists.

### Primary (HIGH confidence)
- [Clerk Expo Quickstart](https://clerk.com/docs/expo/getting-started/quickstart)
- [Expo SQLite + sqlite-vec docs](https://docs.expo.dev/versions/latest/sdk/sqlite/)
- [Drizzle ORM - Expo SQLite](https://orm.drizzle.team/docs/connect-expo-sqlite)
- [Drizzle ORM - Cloudflare D1](https://orm.drizzle.team/docs/connect-cloudflare-d1)
- [Cloudflare D1 docs](https://developers.cloudflare.com/d1/)
- [Cloudflare R2 presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)
- [react-native-executorch docs](https://docs.swmansion.com/react-native-executorch/)
- [Expo Audio docs](https://docs.expo.dev/versions/latest/sdk/audio/)

### Secondary (MEDIUM confidence)
- [@epubjs-react-native/core GitHub](https://github.com/victorsoares96/epubjs-react-native) -- 240 stars, last release Jan 2025
- [react-native-pdf GitHub](https://github.com/wonday/react-native-pdf) -- well-established native PDF
- [react-native-rag GitHub](https://github.com/software-mansion-labs/react-native-rag) -- young but Software Mansion backed
- [Expo local-first architecture guide](https://docs.expo.dev/guides/local-first/)

### Tertiary (LOW confidence)
- [react-native-pdf-jsi](https://github.com/126punith/react-native-pdf-jsi) -- 46 stars, impressive claims but unvalidated
- [@siteed/expo-audio-studio](https://github.com/deeeed/expo-audio-stream) -- real-time audio streaming, Expo 54 compat unconfirmed
- [expo-vector-search](https://github.com/mensonones/expo-vector-search) -- HNSW on mobile, needed only at 100K+ vectors

---
*Research completed: 2026-04-05*
*Ready for roadmap: yes*
