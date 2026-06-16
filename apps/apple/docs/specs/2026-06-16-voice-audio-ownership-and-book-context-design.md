# Voice: single-audio-owner invariant + book-context for the realtime agent

- Date: 2026-06-16
- Status: Design (awaiting review)
- Area: `apps/apple` (RishiVoice, RishiAudio, RishiReader, RishiSearch, app target) + `workers/worker`

## 1. Background & root cause

Two user-reported defects in the reader voice chat motivate this design.

### 1a. Echo / "two voices" (active bug)

Read-aloud (TTS) and a voice-chat session can produce audio **at the same time**.
Earlier device logs show `audio.session.mode mode=tts` + `tts.stream.start` interleaved
with `audio.session.mode mode=voice`. `AudioSessionCoordinator`
(`Packages/RishiAudio/Sources/RishiAudio/Coordinator/AudioSessionCoordinator.swift`)
reconfigures the shared `AVAudioSession` category when voice takes over, but it does
**not own the TTS playback engine** — `ReadAloudController`'s `AVAudioEngine`/player keeps
running. Result: two concurrent audio streams → echo.

A prior fix made the *voice session* itself single-instance
(`VoiceSessionPresenter.start` claims `isPresenting` synchronously). That removed the
"two voice sessions" path but does nothing about TTS-vs-voice overlap.

### 1b. Voice "knows nothing about the book"

Research traced the full book-context (RAG) pipeline. Wiring is intact (the on-device
`BookContextResponder` spawns; the worker registers the `bookContext` tool). The model
knew nothing for two compounding reasons:

1. **Empty context snapshot (primary).** `VoiceSessionPresenter.start` calls
   `session.start(language:"en", bookId:bookId)` and never supplies
   `currentPage/pageText/outline/activeParagraphText` (the params exist on
   `RealtimeVoiceSession.start` but default to nil). The worker prompt therefore renders
   "(No page text available)", no outline, and **no book identity (not even the title)**.
   The prompt also steers the model away from the `bookContext` tool for current-page /
   orientation questions. So "what is this book about" is answered from nothing.
2. **No index for older books (secondary).** Indexing runs **only** at
   `BookFileStorage.importBook`. There is no backfill, so any book imported before the
   feature (or mid-index, or where Core ML fell back to `IdentityEmbedder`) stays
   `.notIndexed`; the responder then returns the cold-start sentinel ("still being
   indexed") instead of passages.

User priority: make the **RAG-via-tool path work** through the existing HNSW pipeline so
the agent can pull extra context, in addition to sending current reading context.

## 2. Goals / non-goals

Goals:
- Enforce **exactly one audio owner at a time** across features (voice ↔ read-aloud),
  centralised in the singleton that owns the resource.
- The realtime agent always knows **what book it is in** and can retrieve passages via the
  `bookContext` tool against a real index.
- Pre-existing un-indexed books get indexed **in the background**, with an unobtrusive
  progress affordance, and the voice entry point reflects index readiness.

Non-goals (explicitly out of scope):
- "Index exists but no good match for this specific query" handling — user flagged as very
  hard; keep the responder's top-k best-effort and revisit later.
- Replacing engines (Readium/PDFKit/GRDB/AVFoundation/USearch) — call patterns only.

## 3. Resolved decisions

- **Audio enforcement = coordinator preemption hook** (Approach A): the invariant lives in
  `AudioSessionCoordinator`, the singleton that owns the AVAudioSession.
- **Voice button is NOT gated on index readiness.** It is enabled as soon as the reader can
  supply page-context (Component 2). The indexing chip shows progress; until the index is
  `.ready` the `bookContext` tool degrades gracefully (the responder's cold-start sentinel).
  Rationale: with reading context sent, voice is useful immediately; gating it would
  needlessly block voice during a long index. (Auth + Pro entitlement gating still applies.)
- **Book identity is added to the worker prompt** → requires a `workers/worker` change and
  redeploy. Approved.

## 4. Components

### Component 1 — Single-audio-owner invariant (fixes echo)

`AudioSessionCoordinator` becomes the true arbiter. Owners register a preemption handler
when they acquire a mode; acquiring a new mode first preempts the previous owner.

- Extend `requestActiveMode(_:)` so the caller registers a `preempt: () async -> Void`
  (e.g. `requestActiveMode(.voice, onPreempt: { await session.end() })`). Store the current
  owner's handler.
- When a *different* mode is requested, the coordinator `await`s the stored handler (the
  previous owner actually stops — TTS tears down its engine; voice ends its session) BEFORE
  applying the new configuration. Then it swaps the handler.
- `ReadAloudController` registers `onPreempt: { await self.stop() }` when it begins
  playback; `VoiceSessionPresenter`/`RealtimeVoiceSession` registers
  `onPreempt: { await self.end() }` when it goes to `.voice`.
- Net invariant: at most one audio owner; the loser is fully stopped, not just
  reconfigured. Symmetric (any future audio feature participates by registering a handler).

Data flow: `voice.start → coordinator.requestActiveMode(.voice, onPreempt:) →
coordinator awaits TTS.preempt() → ReadAloudController.stop() → engine torn down →
configurator.configure(voice) → session live`.

### Component 2 — Send reading context + book identity to the model

Widen the reader → voice seam so the reader supplies a context snapshot at launch:
**book title/author, current page (number), page text, outline, active paragraph.**

- `ReaderVoicePresenter.presentVoice` (RishiReader seam) carries the reader's current
  context (either a `BookContextSnapshot`-shaped value or a `@MainActor` closure the app
  layer invokes to read it from the reader view model at start time).
- `VoiceSessionPresenter.start` forwards it into the **already-existing** params of
  `RealtimeVoiceSession.start(currentPage:pageText:outline:activeParagraphText:)` →
  `BookContextSnapshot` → POST body → worker.
- `workers/worker` (`renderRealtimeInstructions` / `build-realtime-agent.ts`): add a
  **book-identity** section (title + author) to the system prompt so the model always
  knows the book even before any tool call. Redeploy.

The exact reader accessors (EPUB/PDF view models for page text + outline + title) are
nailed down in the implementation plan; the plumbing target (`RealtimeVoiceSession.start`
params) already exists.

### Component 3 — Make RAG work: background backfill + recovery

- **Backfill trigger:** when a book is opened in the reader, check
  `BookSearch.status(bookId:)`; if `.notIndexed`, schedule the same background indexing path
  used at import (`RishiSearchIndexingHook.scheduleIndexing` /
  `IndexBuilder.buildIndex`). This heals pre-existing books.
- **Recovery:** if the `bookContext` search reports the index missing/`.notIndexed` at
  query time, kick (re)indexing rather than only returning the cold-start sentinel.
- **Embedder integrity:** surface/log when `CoreMLMiniLMEmbedder` falls back to
  `IdentityEmbedder` (`rag.embedder.fallback_identity`) so we can detect semantically-dead
  indices; do not silently degrade.

### Component 4 — Indexing indicator (UI); voice button NOT gated

- Expose `BookSearchStatus` for the open book as a `@MainActor` observable to the reader
  (a small status provider/view model; no view reads `BookSearchStatus` today).
- Voice toolbar button (`reader.toolbar.voice`, both EPUB + PDF) stays **enabled regardless
  of index status** (it already gates on auth + Pro entitlement). Voice launches with
  page-context immediately; deep book search simply warms up in the background.
- A **small glass-material chip, bottom-right, small font**, shows e.g. "Indexing… 40%"
  derived from `BookSearchStatus.indexing(chunksDone:chunksTotal:)`; it is intentionally
  low-salience (does not pull attention from reading) and disappears at `.ready`.

### Component 5 — Testing strategy (TDD, Swift Testing)

Failure points + auto-recovery, asserting behaviour not implementation:
- **Audio exclusivity:** requesting `.voice` while `.tts` is active invokes the TTS
  preempt handler exactly once and stops it before configuring voice; symmetric for
  read-aloud preempting voice. No path leaves two owners active.
- **Snapshot content:** launching voice from the reader produces a `BookContextSnapshot`
  carrying title + current page text + outline (not just `bookId`); worker body encodes
  them.
- **Backfill:** opening an `.notIndexed` book schedules indexing; status transitions
  `.notIndexed → .indexing(…) → .ready`.
- **Recovery:** a `bookContext` query against a missing index triggers (re)index rather
  than only sentinel.
- **Responder real-fixture:** for an indexed real fixture (e.g. `how-to-prove-it.pdf`, not
  just the trivial seeded sample) the responder returns real passages for a relevant query.
- **Button availability:** voice button is enabled even while `.notIndexed`/`.indexing`
  (given auth + entitlement); the indexing chip reflects progress; the `bookContext` tool
  returns the graceful cold-start sentinel until `.ready`.
- **Embedder fallback** is observable (logged/surfaced), not silent.

## 5. Workstreams & suggested sequencing

Although delivered as one design, implementation splits into independently shippable
workstreams (plan will order them):

1. **Audio ownership invariant** (RishiAudio + ReadAloudController + VoiceSessionPresenter)
   — fixes the active echo bug first.
2. **Reading-context snapshot + worker book-identity** (RishiReader seam + presenter +
   worker + deploy) — fixes "knows nothing" immediately.
3. **RAG backfill + recovery** (RishiSearch + indexing hook + responder).
4. **Button gating + indexing indicator UI** (RishiReader + app observable).

## 6. Risks / notes

- Decision (resolved): voice is **not** hard-gated on index readiness — it launches with
  reading context immediately, and the indexing chip communicates that deep book search is
  still warming up.
- Worker prompt change requires a redeploy of `rishi-worker` to `api.fidexa.org`.
- Build/verify discipline: per `apps/apple/CLAUDE.md`, confirm a green build before/after;
  subagents must not run `xcodebuild rishi`; orchestrator runs the full build gate and
  greps for the literal `** BUILD SUCCEEDED **` marker.
