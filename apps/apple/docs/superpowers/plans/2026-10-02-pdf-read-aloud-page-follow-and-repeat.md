# PDF Read Aloud Page Follow and Repeat Implementation Plan

> **For agentic workers:** Implement the checked tasks on `main`. Keep each change bounded and request an independent review after implementation.
>
> **Status:** Plan and implementation adversarial review complete — **PASS** (plan: 10 rounds; implementation: 4 rounds; 0 open Critical/High/Medium issues).

**Goal:** Fix #259 so PDF narration turns the visible page through successive boundaries and a deliberate Next page action keeps reading there; fix #260 so Repeat starts at the current spoken passage and continues through the rest of the page.

**Architecture:** The live app uses the unified Readium `ReaderViewModel` and `ReaderNavigatorCoordinator`; the older `PDFReaderViewModel` and `PDFReaderView` are not on this playback path. Keep Readium's publication synthesizer as the speech cursor. Compare auto-follow targets to the **visible** navigator locator. Derive PDF paragraph boundaries from PDFKit line geometry and preserve a mapping from each spoken Readium segment to its **paragraph start**; Repeat restarts there, even when one paragraph spans several utterances. Preserve the existing stop rule for unrelated manual navigation.

**Tech stack:** Swift, SwiftUI, Readium 3 `PublicationSpeechSynthesizer`, PDF navigator, Swift Testing, Xcode build.

---

## Verified research

- `ReadAloudController.startReader` uses `PublicationSpeechSynthesizer`, with `CustomTTSTokenizer` in sentence mode for PDF. Its `.playing` callback stores a spoken locator and immediately invokes `ReaderDestination`'s `onReadAloudPositionChange`, which sets `ReaderViewModel.latestLocator` to that spoken locator.
- `ReaderReadAloudPresenter` then calls `ReaderNavigatorCoordinator.followReadAloudLocator`. Its PDF same-page check currently compares the target to `viewModel.latestLocator`, which already denotes the **spoken** page. Thus it can skip the necessary navigator `go(to:)` even while `visibleNavigatorLocator` remains on the prior page. The same method discards new targets while its one follow task is in flight.
- Readium's installed `PDFResourceContentIterator` uses a locator's page/position/progression to select its starting page, and yields one `TextContentElement` for that whole page. It does not interpret `Locator.Text` as a sub-page start. `ReadAloudController.repeatCurrent()` calls `synthesizer.start(from: currentLocator)`, while the tokenizer's initial one-shot trim is already consumed, so repeating starts at that page's first utterance. `currentLocator` can also be a narrowed spoken range; `readiumState` retains the complete `Utterance` and its locator. A mid-page selection changes the tokenizer's segment boundaries; Repeat must reapply that original trim before locating the active segment.
- Readium's `PublicationSpeechSynthesizer.playNextUtterance` sets `.stopped` if its iterator returns nil, even if the task was canceled by a later `start(from:)`. The app delegate treats `.stopped` as terminal and invalidates playback generation. Reusing one synthesizer object across a restart therefore cannot distinguish a stale old-task stop from genuine end-of-book.
- The current `CustomTTSTokenizer` packs adjacent PDF sentences up to 400 characters without observing PDF paragraph boundaries. One long paragraph can yield several utterances and two short adjacent paragraphs can become one utterance. The active utterance locator alone is therefore **not** the beginning of the current paragraph. `PDFReadAloudParagraphs` already recovers paragraph boundaries using `PDFPage.selectionsByLine()` and `PdfParagraphGrouper`, but the live unified reader does not use those boundaries for speech. Readium's PDFKit `pageText(at:)` returns `PDFPage.string`, so its page text and a dedicated PDFKit page can share stable UTF-16 offsets after verifying exact equality.
- `ReaderScreen.goForward()` delegates to `ReaderPageNavigator.goNext()`. Its resulting location callback passes through `ReaderViewModel.onUserNavigation` and `ReaderDestination`, where a different PDF page currently resolves to `.stopPlaying`. The repo has an explicit test for that generic navigation policy. A deliberate Next page control needs a narrow intent so arbitrary swipes keep their present rule.
- Existing `PDFReadAloudPageBoundaryUITests` cover TTS Next and auto advance, but the feature needs focused deterministic tests for navigation coalescing and restart selection. Do not treat old `PDFReadAloudPageContinuationTests` as proof of the live path; they exercise `PDFReaderViewModel`.

## Consumer and call-site audit

| Behavioral seam | Producer | Consumers and required action |
|---|---|---|
| Spoken PDF locator | `ReadAloudController` delegate | `ReaderDestination` updates `ReaderViewModel` narration position; `ReaderScreen` observes it; `ReaderReadAloudPresenter` highlights and follows; coordinator must compare with `visibleNavigatorLocator`. |
| Canceled Readium utterance | `CustomTTSEngine.speak` resumes after settings load | `onSpeakRange` mutates Readium state; a canceled old invocation must return before the range callback, while the controller checks restart target/epoch before publishing a queued state. |
| PDF follow navigation | `ReaderNavigatorCoordinator.followReadAloudLocator` | `ReaderReadAloudPresenter.apply` and `.follow`; `ReaderNavigatorCoordinator.handleLocationChange` must correlate the observed PDF page with the pending target before passing `isProgrammatic` to `ReaderViewModel.didChangeLocation`. `navigateToReadAloudParagraph` and `goToSharedPosition` also use the programmatic token and need identity-scoped cleanup. |
| Repeat control | `ReaderAudioChromeOverlay`, `ReaderDestination` error retry, `ReadAloudController.repeatCurrent` | PDF reads the active utterance locator's tagged paragraph start and restarts from the full paragraph; EPUB and legacy bridge retain their current behavior. |
| PDF passage extraction for navigation/prefetch | `ReaderViewModel.pdfSentences` | `paragraphsForUserNavigationIntent` and `firstParagraphForPageEntryPrefetch` must use the same paragraph-bounded PDF tokenization as active speech; otherwise their text comparison/cache keys diverge. |
| Explicit reader Next page | `ReaderScreen.goForward` (tap, arrow and reader control paths), `ReaderPageNavigator.goNext` | `ReaderNavigatorCoordinator` tags only the observed callback causally linked to the outstanding PDF `goForward`; `ReaderViewModel` forwards its request ID through a separate callback; `ReaderDestination` validates the original speech session before repositioning. Unrelated swipe/navigation and shared follower policy remain intact. |
| TTS Next/Previous unit | `ReaderAudioChromeOverlay`, Now Playing/CarPlay via `ReadAloudController.next` / `.previous` | For active PDF playback, enqueue each signed skip on the main actor, resolve it from a stable full-page utterance ordinal, and install a fresh synthesizer. Two Next commands move two utterances; Next then Previous returns to the original utterance. Never call Readium `next()` / `previous()` on the same PDF synthesizer. EPUB and legacy bridge keep their current calls. Automatic Readium progression after an utterance finishes still uses the active synthesizer normally. |

## Implementation order

### Task 1 — #259: keep the visible PDF page aligned with speech

**Files:**
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderNavigatorCoordinator.swift`
- Add or update focused tests in `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/PDF/` (navigation decision / queued target, with a fake navigation seam if necessary)

- [ ] Add a failing focused test: spoken page advances from 1 to 2 while visible page remains 1; following page 2 must request navigation. A second target (page 3) arriving before page 2's `go(to:)` returns must be processed, and repeated same-page range callbacks must not request duplicate turns. Use a controllable navigator/test seam so `go(to:)`, its callback, cancellation, and result can be ordered independently.
- [ ] In the PDF branch of `followReadAloudLocator`, compare `locator.locations.page` with `(navigator as? PDFNavigatorViewController)?.currentLocation?.locations.page ?? viewModel.visibleNavigatorLocator?.locations.page`. Never compare against `latestLocator`, which is overwritten by narration. When neither visible source is available, attempt the follow rather than declaring a same-page no-op.
- [ ] Replace the `readAloudFollowTask == nil` drop behavior with one latest pending locator and a serial drain. Give each drain a monotonic `followGeneration` and capture `ObjectIdentifier(navigator)` before awaiting `go(to:)`. `clearReadAloudHighlight`, navigator replacement, or a new speech session increments the generation, clears the pending target and token, and cancels the task. After every await, inspect `Task.isCancelled`, `isFollowingReadAloud`, generation, and navigator identity **before** touching tokens, clearing `readAloudFollowTask`, or launching the next target. In a `defer`, clear the task only if that drain still owns it; a canceled old drain must never erase a newer drain.
- [ ] Replace the count-only PDF programmatic callback token with a record `(requestID, navigatorIdentity, targetHref, targetPage, followGeneration, callbackObserved)`. In `handleLocationChange`, mark a callback programmatic only when its navigator identity and PDF page/href match that record; an unrelated callback is a user turn and retires the stale record. On `go(to:) == false`, clear only the same request ID. On `go(to:) == true` with no matching callback (Readium may succeed without emitting `locationDidChange`), retire that request ID before returning from the drain so it cannot swallow the next user swipe. A late callback for the spoken PDF page may still be classified as a same-page follow through the visible/spoken page comparison, without leaving a standing token. Keep the existing EPUB token path but guard its failure cleanup by request ID so an old task cannot clear a replacement token; apply the same ID-scoped cleanup to `navigateToReadAloudParagraph` and `goToSharedPosition`.
- [ ] Add ordering tests: unrelated PDF callback while a follow is pending remains user navigation; matching callback is programmatic; `go(to:)` false clears the token; `go(to:)` true with no callback clears it; a canceled old follow returning after `clearReadAloudHighlight` and a new follow cannot clear the new task or token; a late old callback cannot mask a manual page turn. Run the focused tests and verify successive page targets reach page 3.

### Task 2 — #260: repeat the current Readium PDF utterance

**Files:**
- Modify `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`
- Modify `apps/apple/rishi/rishi/Audio/CustomTTSEngine.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Text/PdfParagraphGrouper.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/PDF/PDFReadAloudParagraphs.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/CustomTTSTokenizer.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderViewModel.swift`
- Add `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/PDF/PDFNarrationParagraphMap.swift`
- Add an internal `ReadAloudPDFRestartCursor` in `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`
- Add tests in `apps/apple/rishi/rishiTests/ReadAloudControllerTests.swift`, `apps/apple/rishi/rishiTests/Audio/CustomTTSEngineTests.swift`, `apps/apple/rishi/rishiTests/PackageTests/RishiCore/RishiCoreTests/Text/PdfParagraphGrouperTests.swift`, and `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/PDF/`

- [ ] Add focused failing tests for literal paragraph semantics: (a) a layout paragraph longer than 400 characters produces multiple utterances; while its second utterance plays, Repeat starts at **the paragraph's first utterance** and continues through later utterances and the next paragraph; (b) two adjacent short layout paragraphs that the current 400-character packer would combine are emitted as separate utterances, and Repeat from paragraph 2 starts at paragraph 2, never paragraph 1. Cover duplicate paragraph text, pause/Repeat, and page-boundary continuation. Add a mid-page selection test: start inside paragraph 2, advance to paragraph 3, Repeat, and hear paragraph 3 from its beginning; also Repeat while still in partial paragraph 2 and hear **its full paragraph beginning**, not the selection offset.
- [ ] Expose `PdfParagraphGrouper.lineGroups(from:) -> [Range<Int>]` using the exact existing gap/indent decisions, then have `paragraphs(from:)` join those groups so old extraction and narration cannot diverge. Add `PDFReadAloudParagraphs.paragraphRanges(from:pageText:) -> ParagraphRangeResult`: for each nonblank `PDFPage.selectionsByLine()` selection, get native PDFKit UTF-16 ranges using `numberOfTextRanges(on: page)` and `range(at: index, on: page)` (the installed `PDFSelection.h` declares `numberOfTextRangesOnPage:` / `rangeAtIndex:onPage:`). Check each range is nonempty, is not `NSNotFound`, lies within `(pageText as NSString).length`, and appears in nondecreasing nonoverlapping reading order. Validate its substring content against the line selection text, allowing only defined whitespace normalization; check that Readium's page text equals `page.string`. Turn each grouped first/last native range into a paragraph range. **Never search for line text** to invent offsets: repeated identical lines make substring search ambiguous. If native ranges or validation fail, use only explicit blank-line boundaries in the page string; if no such boundary exists, return `.unavailable` for paragraph mapping and keep playback safe without claiming a paragraph start for Repeat. Add tests with duplicate/repeated lines and deliberately invalid/out-of-bounds native range inputs.
- [ ] `PDFNarrationParagraphMap` owns a dedicated PDFKit document opened from `ReaderViewModel.documentURL` and a private cache of immutable per-page `ParagraphRangeResult` values. Its document and cache are accessed only inside one `NSLock.withLock` synchronous critical section; no `await` occurs under the lock. Return copied immutable ranges and do sentence tokenization outside the lock. Readium can overlap a canceled iterator with another task on the **same** synthesizer, so per-synthesizer ownership alone is insufficient. Create a fresh locked map for a replacement synthesizer as well. Wire the map into `startReader`'s PDF tokenizer factory; keep the EPUB factory unchanged. For each Readium PDF page `TextContentElement`, split its single page segment into paragraph `TextContentElement`s at verified UTF-16 ranges **before** sentence tokenization. Copy the page locator and attach the paragraph's stable page-local start offset to `locations.otherLocations["rishiParagraphStartUTF16"]`; also tag each final packed segment with a stable page-local `rishiUtteranceOrdinal` after packing **from the canonical, untrimmed full-page utterance list**, while retaining the standard `page=` fragment/position for navigation. For PDF, extend `CustomTTSTokenizer`'s sentence path to use the `Range<String.Index>` values already returned by `makeLineBreakTolerantSentenceTokenizer`: convert each lower/upper bound to UTF-16 and add the paragraph's verified page-base offset **before** constructing the sentence segment. Carry that exact source range through packing; a packed utterance owns the ordered union of its constituent source ranges plus their output-text ranges. The packer's inserted join `" "` has **no source offset**. Gaps in source text between constituents map forward to the next constituent, and selection inside a source constituent maps to its output-text offset; never find a span by searching for sentence text, since repeated sentences are indistinguishable by value. Readium's installed `makeTextContentTokenizer` copies segment locators while changing only `.text`, so the paragraph metadata survives. Call the existing sentence tokenizer separately for each paragraph, so `packPDFSentences` may split a long paragraph but **cannot merge two paragraphs**. For `.unavailable`, use the safe page text tokenizer for continued speech, still tag a stable page-local utterance ordinal for Next/Previous, but omit paragraph metadata; Repeat reports that a precise paragraph start is unavailable rather than restarting the whole page. Verify source-span/locator metadata through tokenization, packing, highlighting, and restart.
- [ ] Route `ReaderViewModel.pdfSentences` through this same paragraph-bounded tokenizer using its `documentURL`, so destination matching and first-passage prefetch see the same utterance strings as playback. Keep page-limited extraction and the existing EPUB path. Add a test comparing `pdfSentences` output with the synthesizer tokenizer's segments on a page with two adjacent short paragraphs and a >400-character paragraph.
- [ ] For a selected start, resolve `startLocator.text` to one stable UTF-16 offset in the original untrimmed page text using its `before + highlight` context, requiring a unique contextual match (or an exact source selection range when available); an ambiguous repeated match is a bounded failure, never a silent first-occurrence guess. Then locate its containing paragraph range. Build and assign ordinals to the **full-page canonical utterances first**. Find the first utterance whose ordered constituent source spans contain the offset, or the next constituent if the offset falls in a source gap; translate within that constituent's source/output range map and trim only that first utterance's spoken text, omitting any preceding inserted join space. Retain its canonical `rishiUtteranceOrdinal`, original constituent source spans, and containing **full** paragraph-start metadata. All following utterances keep their canonical boundaries and ordinals. Keep that original page offset in session state; do not retokenize the shortened text to assign new ordinals. Thus Next from a partial canonical utterance targets its canonical successor, and Previous from its successor returns to that utterance's **full** text. On Repeat, read the active `.playing`/`.paused` utterance locator's `rishiParagraphStartUTF16` and `page=` values, rebuild the full-page paragraph map, drop earlier paragraphs, and start at the first utterance of that full paragraph. If the offset or map cannot be resolved, surface a bounded failure rather than replaying an unrelated page start. EPUB retains the existing `CustomTTSTokenizer.trimming` path.
- [ ] Extract a private synthesizer builder from `startReader` accepting the current publication, settings, engine/session token, tokenizer cursor, and delegate. Repeat and explicit page turn use it to create a **new** `PublicationSpeechSynthesizer` without calling `stopCurrentPlayback` or changing playback owner, token, presence, Now Playing, or allowance state. Install the new synthesizer as `readiumSynthesizer` first; then stop/cancel the old synthesizer; then call `new.start(from: targetLocator)`. The old object's `.playing` and `.stopped` callbacks fail the existing `readiumSynthesizer === synthesizer` identity guard even when its canceled iterator returns nil. A genuine `.stopped` from the active new synthesizer retains the existing terminal cleanup. Keep the playback session token and increment a local restart epoch.
- [ ] In `repeatCurrent`, guard-let and capture the active `readiumSynthesizer` object and non-nil `playbackSessionToken`, and capture `playbackGeneration` **before** `await coordinator.requestActiveMode(.tts)`, along with the active utterance locator's page and paragraph-start offset. After that await, require success and recheck `readiumSynthesizer === capturedSynthesizer`, `playbackSessionToken == capturedToken`, the captured generation is still current, and `ttsState.ownsPlaybackSession(capturedToken)` before constructing the cursor or installing a replacement. If any check fails, return without touching the newer session or its tokenizer cursor. Then construct a cursor that drops all paragraphs before the captured paragraph offset and begins with **the first segment of that paragraph**, and replace the captured synthesizer. Preserve the original selection offset for mapping during the session; never use the current utterance boundary as the Repeat boundary. Do not apply PDF cursor logic to EPUB or the legacy bridge.
- [ ] Change `ReadAloudController.next(lease:)` and `.previous(lease:)` for **active PDF Readium** sessions: synchronously enqueue a `+1` or `-1` step on the main actor before any await, with playback token/generation and remote-command lease. A single ordered PDF skip drain owns a logical `(page, canonical rishiUtteranceOrdinal)` cursor initialized from the active `.playing`/`.paused` utterance; every queued step resolves from the **last accepted logical target**, including while a replacement has not yet emitted `.playing`. Resolve adjacent utterances from the same paragraph-bounded full-page tokenizer output (next/previous ordinal on the current page, otherwise scan forward/backward to the nearest nonempty PDF page through publication content). Construct a fresh cursor that starts at that exact target ordinal, and replace the synthesizer using the identity ordering above. Recheck token/generation, current synthesizer identity, drain ownership, and the step's lease after every await; after a successful replacement, update the drain's expected synthesizer identity and logical cursor before consuming the next step. A stale callback never rewinds the logical cursor. Keep the logical target until the active synthesizer confirms it, then let accepted automatic `.playing` callbacks update the cursor once the queue is empty. Clear pending steps on session teardown, Repeat, or explicit page restart; an ownership change may invalidate old-session steps, but **a same-session synthesizer replacement by the skip drain must never silently discard a queued command**. Preserve existing terminal behavior at last/first utterance. Never invoke `readiumSynthesizer.next()` or `.previous()` on the active PDF object; EPUB and legacy bridge retain their current behavior. Automatic forward progression of the active synthesizer after successful speech remains unchanged.
- [ ] In `CustomTTSEngine.speak`, place `try Task.checkCancellation()` **immediately after** `await settingsStore.load(userId:)` and immediately before `onSpeakRange(...)`, with no suspension between the check and callback. This closes the existing window where a canceled old utterance can publish a range after settings load and replace the new Readium state. Keep the existing cancellation/stop gate for audio playback.
- [ ] Add a restart epoch and expected first utterance/page target to `ReadAloudController` for PDF Repeat and explicit page restart. In its Readium delegate, verify session token, **new synthesizer identity**, `synthesizer.state == state`, and the restart target before publishing position/highlight from the first callback after restart. Clear the target fence only after the expected new utterance appears; increment/clear the epoch on a newer restart or session teardown. An old same-page passage preceding the repeat target must not overwrite the new position. Do not rely on live-state equality alone, because stale `onSpeakRange` can itself replace a synthesizer's live state.
- [ ] Add a deterministic delayed-settings test: suspend `settingsStore.load` for utterance A, cancel A by restarting at utterance B, release A's load, and assert A never invokes `onSpeakRange` or updates Readium/controller position. Separately inject a queued stale delegate `.playing` event after restart and assert the target/epoch fence rejects it, including a same-page previous passage. Order an old iterator returning nil and emitting `.stopped` **after** the new synthesizer starts; assert the new session stays active and continues. Then let the active new synthesizer genuinely exhaust the last PDF page and assert its `.stopped` still tears down playback.
- [ ] Add a Repeat ownership race test: suspend `requestActiveMode(.tts)`, replace playback with a newer PDF session while the old Repeat awaits, then release the mode request. Assert old Repeat neither replaces/stops the newer synthesizer nor resets its cursor, and the newer session continues from its own passage.
- [ ] Add a concurrent tokenizer regression test: directly overlap two tokenizer invocations on one locked paragraph map while the first is held inside range extraction, then release it. Assert PDFKit/cache access remains ordered and both immutable results have valid ranges. Separately run rapid TTS Next/Previous through their **new-synthesizer** path and assert the canceled old object's late result cannot publish a passage; cover the replacement map operating concurrently with the old map.
- [ ] Add explicit skip ordering tests: hold the old PDF iterator before it emits `.playing`, press TTS Next (and separately Previous), let the replacement synthesizer begin its target utterance/page, then release the old iterator so it emits a late `.playing`; visible page and speech must not regress. Suspend the first target resolution, send Next twice, then release it and assert the final target is **two** canonical utterances ahead; send Next then Previous under the same ordering and assert the original utterance is restored. Cover within-page and cross-page targets, an older target callback after a newer skip, and canceling queued steps on a new session/Repeat/explicit page restart. Start from the middle of an utterance via selection, send Next then Previous, and assert stable canonical ordinals target the next full utterance then the original full utterance without replaying the page beginning. Add a duplicate-sentence fixture with the same sentence text twice on one page: select inside its second occurrence, verify its distinct native-derived source span and canonical ordinal survive packing's inserted join space, then Next/Previous must navigate relative to the second occurrence. Keep a separate test that ordinary automatic progression crosses pages on one active synthesizer.
- [ ] Run the focused tests and check that failure retry from `ReaderDestination` and the overlay Repeat control reach this same path.

### Task 3 — #259: deliberate Next page while playing

**Files:**
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderPageNavigator.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderNavigatorCoordinator.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderViewModel.swift`
- Modify `apps/apple/rishi/rishi/Reader/ReaderDestination.swift`
- Modify `apps/apple/rishi/rishi/Audio/ReadAloudController.swift`
- Modify `apps/apple/rishi/rishiTests/Audio/ReadAloudControllerNavigationIntentTests.swift` or a focused destination/navigation test
- Modify `apps/apple/rishi/rishiTests/ReaderNavigatorCoordinatorFollowTests.swift` and `apps/apple/rishi/rishiTests/PackageTests/RishiReader/RishiReaderTests/ReaderViewModelTests.swift` for the explicit source callback contract

- [ ] Add a failing test for a PDF speech session on page 1: a deliberate reader Next page action that lands on page 2 keeps the **same** playback session and starts speech on page 2. A generic swipe to unrelated text still follows the current stop policy. Include no navigator, failed boundary turn, successful callback-free turn, unrelated callback before the requested turn, callback before/after `goForward` returns, rapid turns, and an ordinary navigation extraction completing after the utterance or playback session changed. Test a same-session utterance advancing to page 2 while `goForward` is pending (keep reading there) and advancing to **page 3** while the observed destination is page 2 (restart at page 2) separately from a replacement playback session (reject old request).
- [ ] Make `ReaderPageNavigator.goNext(explicitForwardID: UUID? = nil) async -> Bool` call `await navigator.goForward(...)` directly and return `false` when no navigator exists. Its `Bool` means the PDF's **visible page actually moved**, determined from origin and final `currentLocation`, not merely Readium's `Bool` or the synthetic haptic counter. `ReaderScreen.goForward` launches one `@MainActor` Task and awaits it; the task invokes `onExplicitPageForward` to get an ID and passes that ID into `goNext`. The page navigator registers the ID immediately before calling Readium and completes its coordinator record on every exit. EPUB passes no ID and retains existing navigation behavior.
- [ ] Add `onExplicitPageForwardCompleted: ((UUID, Bool) -> Void)?` to `ReaderScreen`, wired by `ReaderDestination` to `ReadAloudController.completeExplicitForward(id:didMove:)`. Invoke this exactly once from the `goForward` task's all-exit path, including absent navigator, thrown/canceled task path if introduced, Readium `false`, and unchanged final page. On `didMove == false`, the owner clears only that ID so a later unrelated turn cannot reuse it. On `didMove == true`, retain the owner ID only until a tagged callback or the coordinator's callback-free fallback is handled; never leave it armed after completion. A replaced session or newer ID rejects an old completion.
- [ ] Add `onExplicitPageForward: (() -> UUID?)?` to `ReaderScreen`; `ReaderDestination` returns an ID only for an active local PDF speech session and records `(ID, playbackSessionToken, playbackGeneration, navigationIntentGeneration, spokenPage, activeUtteranceEpoch)`. Register the same ID plus `ObjectIdentifier(navigator)` and origin **visible** page on `ReaderNavigatorCoordinator` immediately before the PDF `goForward` call. Its `handleLocationChange` labels an observed location with that ID only when the same navigator reports the expected forward PDF page from that origin during the operation; unrelated page/href, replacement operation, and failure flow through the usual user path. Do not use a free-floating boolean that the next arbitrary callback can consume.
- [ ] Have coordinator completion return whether a matching callback was observed and the final `currentLocation` page. It may mutate only a request with the same ID and navigator identity; an older `goForward` result cannot clear a newer turn. A `false` result or unchanged page clears the coordinator record; the new `onExplicitPageForwardCompleted` hook clears the owner's ID. If the callback was already observed, completion leaves the controller ID for the destination handler, which may still be queued on the main actor. If `goForward` succeeded and `currentLocation` advanced but no callback arrived, call `viewModel.didChangeLocation(currentLocation, isProgrammatic: false, explicitForwardID: id)` exactly once, then clear the coordinator request. Retain at most a one-shot, identity/page-matched late-callback marker; `handleLocationChange` consumes a matching delayed duplicate **without calling** `didChangeLocation` again. Retire that marker on a mismatching callback, a subsequent navigation, or session teardown. This marker is separate from the programmatic follow token and cannot consume a different page.
- [ ] Extend `ReaderViewModel.didChangeLocation` with `explicitForwardID: UUID? = nil` and add `onExplicitPageForwardNavigation: ((Locator, UUID) -> Void)?`. For a valid tagged callback, update visible/persisted position as usual, then call the explicit callback instead of `onUserNavigation`; for an untagged callback, preserve the existing `onUserNavigation` and prefetch behavior. Keep tests for the default call sites and EPUB behavior unchanged. `ReaderDestination` handles the explicit callback using the supplied ID and destination locator; it does not guess provenance from page order after the fact. Call `readerTour?.userNavigated()` for the explicit path as well.
- [ ] Implement a synchronous `ReadAloudController.restartAtExplicitPage(_ locator: Locator, id: UUID) -> ExplicitForwardPlaybackResult` on the main actor, with cases `.restarted`, `.alreadyReadingDestination`, and `.rejected`. It requires the captured playback token/generation and navigation generation still to match, but **does not reject solely because the same session's utterance epoch changed while `goForward` awaited**. Compare the live synthesizer's spoken PDF page to the **observed destination page**: only when they are equal, keep that active utterance and return `.alreadyReadingDestination`. If live speech is before, beyond, or missing a page, honor the explicit user destination: replace the synthesizer using Task 2's builder and identity ordering, start at the **destination page's first paragraph**, and return `.restarted`. In either success case consume only that ID. A replaced session/newer navigation ID returns `.rejected` without touching current speech. Install Task 2's restart target/epoch fence before `start(from:)`. No destination paragraph extraction, entitlement check, or second playback owner is needed.
- [ ] For the existing ordinary `ReaderDestination.onUserNavigation` path, add playback token/generation and active utterance epoch to `ReadAloudUserNavigationSnapshot`. `ReadAloudController` observes the synthesizer's current utterance epoch even while `acceptsReadAloudPositionUpdates` is false; that flag suppresses stale position publication, not the freshness witness. After `await vm.paragraphsForUserNavigationIntent`, first reject a replaced playback session or superseded navigation generation. If only the utterance advanced, form a fresh snapshot from the live synthesizer state and resolve against the already extracted destination passages before any stop/continue decision. This avoids acting on an old utterance while ensuring the same session does not remain permanently position-fenced. An old session's task must never re-enable updates or stop its replacement.
- [ ] Verify reader Next page from tap and Catalyst arrow calls the same `goForward` method. TTS Next/Previous unit for active PDF uses Task 2's fresh-synthesizer target cursor; EPUB still uses Readium's `next()` / `previous()`. Add a test that a shared follower cannot arm an explicit local forward request.

### Task 4 — Integration and handoff

- [ ] Run focused Swift tests for the new navigation and repeat behavior, plus existing `ReadAloudUserNavigationIntentTests` and tokenizer tests. Resolve failures before widening checks.
- [ ] Typecheck/build the touched Apple app for iPhone Simulator and Mac Catalyst using the repo's existing Xcode scheme/commands. Install and launch the simulator app if feasible. Report commands, outputs, and any environment limit.
- [ ] Independently review the final diff: confirm no old `PDFReaderViewModel` path was mistaken for live production code; no stale follow token swallows a user swipe; no stale repeat restart survives a session change; EPUB and shared follower behavior remain scoped.
- [ ] Manual handoff: on a selectable multi-page PDF, let page 1 finish and observe page 2 then page 3 visible during speech; use TTS Next at a boundary; use reader Next page during speech; press Repeat in a middle passage and confirm it reads that passage then the remainder. Check pause/repeat and last page. State that a successful build/launch alone cannot prove these playback behaviors.

## Explicit out of scope

- Legacy standalone `PDFReaderViewModel` / `PDFReaderView` continuation pipeline.
- Changing generic swipe-to-unrelated-page stop behavior or EPUB pagination.
- Audio synchronization across shared reading devices; the user performs that manual verification separately.

## Adversarial review loop

Each round: review → log findings → update plan → re-review. Independent reviewer records findings here and revisits the updated file before implementation.

### Round 1 — Independent Sol review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | High | `ReaderPageNavigator.goNext` is fire-and-forget, so the proposed completion cannot know whether Readium moved. | Task 3 specifies an awaited `Bool` result and all-exit failure/no-op cleanup. |
| 2 | High | A pending explicit-forward flag can be consumed by an unrelated callback. | Task 3 assigns an ID, navigator identity, and origin page; only the matching in-flight Readium callback is tagged, then the ID is forwarded by `ReaderViewModel`. |
| 3 | High | Count-only programmatic callback token can mask user navigation, including successful callback-free jumps. | Task 1 correlates PDF callback to target page/href/identity, scopes cleanup by request ID, and retires successful callback-free requests. |
| 4 | High | A canceled follow task can resume and clear a newer task or token. | Task 1 fences every post-await mutation by follow generation and navigator identity, with owner-only cleanup. |
| 5 | High | Destination extraction can finish after the narration session or utterance has advanced. | Task 3 makes the explicit-turn destination synchronous, and refreshes the ordinary async-navigation snapshot from live speech after extraction while rejecting replaced sessions. |

**Round 1 result:** Five High findings addressed in the plan. Independent re-review required before implementation.

### Round 1b — Author's cold re-review of revised plan

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 6 | High | Completion might clear an ID after its callback was tagged but before the destination handler consumes it. | Task 3 separates coordinator result cleanup from controller intent ownership; observed callbacks retain the controller ID until handled. |
| 7 | High | A successful turn might return before its callback, while a truly callback-free success still needs a destination and cleanup. | Task 3 uses the navigator's resulting `currentLocation` to synthesize one explicit model update when no callback arrived, then consumes a matching late duplicate without a second model update. |
| 8 | High | A stale result from an older turn could clear a newer request. | Task 3 requires both ID and navigator identity for completion mutation. |
| 9 | High | The ordinary navigation path could remain position-fenced if its utterance changes during extraction. | Task 3 refreshes the same-session snapshot from live synthesizer state and resolves using the already extracted destination passages. |

**Round 1b result:** Author fixes applied. Independent re-review required before implementation.

### Round 2 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 10 | High | `CustomTTSEngine.speak` can resume from a delayed settings load after cancellation and still invoke `onSpeakRange`; delegate live-state equality cannot reject a callback that already replaced live state. | Task 2 adds `Task.checkCancellation()` immediately before `onSpeakRange`, a controller restart target/epoch fence, and a delayed-settings/stale-delegate regression test. |
| 11 | High | No owner completion path exists for absent navigator, failed `goForward`, or unchanged page, leaving an explicit intent armed. | Task 3 adds `onExplicitPageForwardCompleted` from `ReaderScreen` to `ReaderDestination`/`ReadAloudController`, called on all result paths with actual page movement. |
| 12 | High | Rejecting a turn when its original utterance epoch changes during `goForward` loses a valid user request. | Task 3 keeps same-session turns valid and resolves against the **live** spoken page; it retains speech only when already on the destination page and otherwise restarts there. Replacement sessions still reject. Separate timing tests cover both outcomes. |

**Round 2 result:** Three High findings addressed in the updated plan. Independent re-review required before implementation.

### Round 3 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 13 | High | A canceled Readium iterator can return nil and emit `.stopped` after a new `start(from:)`; the delegate then invalidates the new session as if playback genuinely ended. | Task 2 replaces the synthesizer object on PDF restart, installs the new identity before stopping the old one, rejects all old-object callbacks, and tests stale `.stopped` versus genuine active end-of-book. |
| 14 | High | A session started from a mid-page selection has different segment boundaries after the one-shot trim; full-page retokenization may not contain the active segment locator. | Task 2 retains the selection's stable original-page UTF-16 offset and tags emitted segments with the containing full paragraph start; Repeat uses that start, with selection → advance → Repeat coverage. |

**Round 3 result:** Two High findings addressed in the updated plan. Independent re-review required before implementation.

### Round 4 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 15 | High | `repeatCurrent` awaits audio-mode activation; a newer session may replace the captured synthesizer before the old Repeat resumes. | Task 2 snapshots synthesizer identity, playback token, and generation before the await; it rechecks all three plus session ownership afterward and adds a suspended-mode-request race test. |

**Round 4 result:** One High finding addressed in the updated plan. Independent re-review required before implementation.

### Round 5 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 16 | High | An explicit Next destination is lost if narration has advanced beyond it while `goForward` awaits; `.alreadyReached` follows a later page. | Task 3 retains current speech only when its live page **equals** the observed destination. Before, beyond, or unknown pages restart at the user-selected page. A page-3-live/page-2-destination test pins this. |
| 17 | High | `repeatCurrent` restarts at an utterance, while the issue requires the paragraph beginning; 400-character packing can both split a paragraph and combine adjacent paragraphs. | Task 2 derives geometry-based paragraph ranges, splits before sentence packing, tags each utterance locator with its paragraph start offset, and restarts from that full paragraph. Tests cover a >400-character paragraph, adjacent short paragraphs, and selection starts. |

**Round 5 result:** Two High findings addressed in the updated plan. Independent re-review required before implementation.

### Round 6 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 18 | High | Mapping duplicate PDF lines by substring search can assign the wrong UTF-16 offsets or silently cross text order. | Task 2 uses PDFKit's installed native `PDFSelection` range APIs, validates bounds/order/content against `PDFPage.string`, and defines an explicit-blank-line or unavailable fallback; duplicate-line and invalid-range tests are required. |
| 19 | High | Readium may overlap canceled and replacement iterator tasks within one synthesizer, so a per-synthesizer PDFKit document/cache is still shared concurrently. | Task 2 synchronizes the document/cache behind `NSLock`, returns immutable per-page data, tokenizes outside the lock, and tests overlapping canceled-old/new tokenization during rapid Next/Previous. |

**Round 6 result:** Two High findings addressed in the updated plan. Independent re-review required before implementation.

### Round 7 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 20 | High | Locking PDFKit/cache cannot stop a canceled Readium `next()` / `previous()` iterator from publishing a stale `.playing` event on the **same** synthesizer; the controller's synthesizer identity guard would accept it. | Task 2 routes active-PDF TTS Next/Previous through adjacent tagged-utterance resolution and a **new** synthesizer with an exact target cursor. It never invokes Readium `next()` / `previous()` on that PDF object. The old object's late `.playing` fails the identity guard; an ordered regression tests forward and backward skips, including a stale old callback after the target starts. Automatic progression continues on its one active synthesizer. |

**Round 7 result:** One High finding addressed in the updated plan. Independent re-review required before implementation.

### Round 8 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 21 | High | A second rapid PDF Next/Previous command can fail the stale-synthesizer identity check and disappear, so two Next presses may advance only once. | Task 2 adds a main-actor ordered skip queue with a logical target cursor, processes every accepted signed step across fresh-synthesizer replacements, and tests two Next and Next-then-Previous while the first resolution is suspended. |
| 22 | High | A selected start trims and repacks the first page, so an ordinal assigned afterward may not identify its corresponding full-page utterance when Next/Previous builds a replacement. | Task 2 assigns ordinals on canonical untrimmed page utterances before selection, trims only the first spoken canonical utterance, retains its original range/ordinal, and tests Next/Previous from a mid-utterance selection. |

**Round 8 result:** Two High findings addressed in the updated plan. Independent re-review required before implementation.

### Round 9 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 23 | Medium | The plan selects an utterance using an original UTF-16 range, but tokenizer segments carry no source spans and packing inserts whitespace; duplicate sentences can be mapped to the wrong canonical ordinal. | Task 2 derives exact sentence source spans from the tokenizer's returned ranges plus native page offsets, carries ordered source/output spans through packing, treats inserted join spaces as having no source offset, and adds a selected duplicate-sentence ordinal/Next/Previous regression test. |

**Round 9 result:** One Medium finding addressed in the updated plan. Independent re-review required before implementation.

### Round 10 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| — | — | No open Critical, High, or Medium plan issues. | The revised source-span rule, ordered skip queue, paragraph mapping, callback correlation, and restart guards were verified against the relevant call sites and failure paths. |

**Round 10 result:** PASS — 0 open Critical/High/Medium issues. Implementation may proceed.

## Implementation adversarial review loop

### Round 1 — Independent Sol diff review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | High | Repeat filtered to only the target paragraph and skipped the rest of the current page. | Tokenizer now drops only preceding utterances and retains the target paragraph and all later page paragraphs. |
| 2 | High | The initial selection text was applied on every PDF page and suppressed later pages. | A shared one-shot starting-page gate scopes selection trimming to the original page. |
| 3 | High | Replacement synthesizers reverted to the initial voice after a settings change. | Replacement builder reads the current picker settings. |
| 4 | High | Restarting from pause left the controller marked paused while the replacement was playing. | Accepted replacement clears paused state and restores playing status. |
| 5 | Medium | Unavailable paragraph mapping could inherit the previous page's paragraph origin. | Page tokenization removes all inherited paragraph, ordinal, source-span, and selection-offset metadata before adding verified page-local values. |

**Round 1 result:** Five findings addressed; re-review required.

### Round 2 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 6 | High | Readium creates a tokenizer from the factory for each page, so a gate created inside each tokenizer re-applied selection matching on every page. | The PDF selection gate is created once per synthesizer tokenizer-factory lifetime, receives the explicit start page, and is shared across page tokenizers. |

**Round 2 result:** One High finding addressed; re-review required.

### Round 3 — Independent Sol re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 7 | High | Real PDF selection locators provide highlight text without `before` context, so duplicate phrases could not resolve their exact occurrence. | The live PDFKit selection's native UTF-16 start range is attached to the Readium locator, serialized, passed through the factory gate, and verified against selected text before contextual fallback. |
| 8 | Medium | The selection offset remained on later page locators and could contaminate a future resume. | Tokenizer captures the offset for the starting page, then removes the app-owned selection offset from page and utterance metadata. |
| 9 | Medium | The first metadata-leak regression retokenized joined segment text, so its newline context could not match the raw page fixture. | Test now rebuilds a raw page element from original text and cleaned locator metadata. |

**Round 3 result:** Three findings addressed; re-review required.

### Round 4 — Independent Sol final re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| — | — | No open Critical, High, or Medium implementation findings. | Review verified visible page follow, explicit Next ownership, paragraph Repeat continuation, selected-page offsets, ordered skips, replacement voice and pause state, and stale synthesizer callback handling. |

**Round 4 result:** PASS — 0 open Critical/High/Medium issues.
