# DRY Audit Proposal — Deferred Items

Date: 2026-06-13
Author: subagent audit (review before acting)

## TL;DR

One extraction landed (`JSONStringCodableLocator`, 3 call sites in
RishiReader). Six deferred patterns remain. Headline: ISO-8601
`JSONEncoder`/`JSONDecoder` factories are inlined 6× inside
`SyncPayloadCodec` but `RishiSyncTests` won't compile right now (unrelated
upstream change), so the extraction can't satisfy the
tests-must-pass land rule until that is fixed.

## Landed in this audit

1. `b6e966552` — refactor(dry): extract `JSONStringCodableLocator` from 3 call sites in RishiReader

## Deferred — medium-risk extractions

### Pattern 1: ISO-8601 JSON coder factories in SyncPayloadCodec

**Occurrences:** `Packages/RishiSync/Sources/RishiSync/Inbound/SyncPayloadCodec.swift:31,48,68,93,106,122` (6 sites, all in one file).

**Proposed extraction:** Two private static helpers
`Self.iso8601Decoder()` / `Self.iso8601Encoder()` on `SyncPayloadCodec`.

**Why deferred:** Mechanical, in-file, no API change — but
`RishiSyncTests` fails to compile (`SilentPushHandlerTests.swift:106`
missing four ctor arguments — unrelated). Strict land rule requires
green tests; land after that compiles.

**Effort:** small (~20-line in-file diff).

### Pattern 2: SceneStorage codec triplet

**Occurrences:** `rishi/rishi/Mac/SceneRestorationState.swift:60,77,174,184,206,220` — three pairs of `JSONEncoder().encode(...)` + `String(data:encoding:.utf8)` round-trips wrapping `RishiSceneState`, `ReaderRoute`, and `NavigationPath.CodableRepresentation`.

**Proposed extraction:** `JSONStringStorageCodec` helper in the app
target.

**Why deferred:** Each site has a different failure fallback (`""`,
`.default`, `NavigationPath()`). A helper taking a fallback closure
works, but the abstraction's name is "JSON-string-with-fallback" —
premature DRY warning. Three co-located two-liners; extraction is net
neutral or negative.

**Effort:** small if landed; consider not landing.

### Pattern 3: UUID-keyed cache URL helper

**Occurrences:** `BookFileStorage.swift:79,137`, `CoverCache.swift:132,136,155,156`, `PDFThumbnailCache.swift:117,139`, `EPUBUnpackedCache.swift:213,217`.

**Proposed extraction:** `URL+UUIDPathComponent` extension on `URL` in
RishiCore — `func appending(uuid: UUID, suffix: String? = nil) -> URL`.

**Why deferred:** Crosses three packages with per-site suffixes
(`.heic`, `.mtime`, `.jpg`, none). Target package RishiCore is being
edited by the concurrent public-surface audit.

**Effort:** medium.

### Pattern 4: CoverCache fast-path duplication

**Occurrences:** `CoverCache.swift:132,136` (helpers) vs `155,156` (inlined copies in `cachedURLIfFresh`).

**Proposed extraction:** Promote `cacheURL(for:)` / `mtimeSidecarURL(for:)` to `nonisolated static` so the actor's nonisolated fast-path can call them.

**Why deferred:** Actor-isolation change. Moving to `nonisolated static`
needs `cacheDir` threaded as a parameter or marked `nonisolated let` —
small but non-zero risk; current two-liner is harmless.

**Effort:** small.

## Deferred — high-risk extractions

### Pattern 5: Reader view-model lifecycle protocol

**Occurrences:** `PDFReaderViewModel.swift` and `EPUBReaderViewModel.swift` share `loadingState`, `advancePage()`, `hitBoundary()`, `load()`, `flush()` signatures.

**Proposed extraction:** A `ReaderViewModel` protocol in RishiReader.

**Why deferred:** Engine-shaped consolidation — Readium vs PDFKit have
genuinely different `load()` lifecycles, and `apps/apple/CLAUDE.md`
forbids replacing engine call patterns. Better as a view-layer
`ReaderHost<VM>` than a model-layer protocol.

**Effort:** large.

### Pattern 6: AsyncStream-init pattern in audio configurators

**Occurrences:** `AudioSessionConfigurator.swift:66-68` (real) and `:142-144` (fake).

**Proposed extraction:** `AsyncStream.makePair()`-style helper.

**Why deferred:** iOS 17 ships `AsyncStream.makeStream(of:)` natively.
Replacing the pattern is behaviour-equivalent but touches
`@unchecked Sendable` initializers in a strict-concurrency package —
worth its own focused commit, not a DRY pass.

**Effort:** small but isolated.

## Patterns intentionally NOT extracted

- **3× temp-dir + UUID preview helpers in LibraryRootView.swift** — only
  2 in-file occurrences; below the ≥3 threshold. Local clarity is fine.
- **Documents-directory lookup in `AppDependencies.swift:260` and
  `RootView.swift:979`** — 2 occurrences in the app target. Comments at
  both sites explain *why* it's recomputed (avoiding an actor hop at
  view-build time). Extracting would hide that reasoning.
- **`SignpostName`/log-event taxonomies per package** — every package
  defines its own `Log.event` namespace (`audio.*`, `auth.*`, `iap.*`).
  Consolidating into a global enum would force every reader of one
  package to learn the whole vocabulary. Keep local.
- **Three packages declare format-version constants
  (`pdf-v1`, `epub-v1`)** — these are wire-format tags. Extracting
  would couple unrelated lifecycles (PDF locator schema vs EPUB locator
  schema). Keep local.
