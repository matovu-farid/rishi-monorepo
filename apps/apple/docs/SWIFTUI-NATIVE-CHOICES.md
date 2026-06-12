# SwiftUI Native-Choice Deviations (ADR)

- **ADR Number:** ADR-001
- **Date:** 2026-06-12
- **Status:** Accepted
- **Author:** GSD Phase 18 (native-swiftui-audit-and-migration-sweep-for-the-ios-app)
- **Supersedes:** None

## Context

Phase 18 audited the iOS UI surface end-to-end (see `.planning/phases/18-native-swiftui-audit-and-migration-sweep-for-the-ios-app/18-RESEARCH.md`). The audit was triggered by a reader-trap incident in the EPUB reader where `.fullScreenCover(item: $openTarget)` stripped the system navigation bar and edge-swipe-back gesture; when chrome auto-hide hid the in-app `xmark` button, the user had zero system escape (quick fix `dbc1c7d6d` set `initiallyVisible: true` as a stopgap). The audit catalogued every non-idiomatic SwiftUI pattern across the app target plus all `RishiLibrary`, `RishiReader`, `RishiSettings`, `RishiBilling`, `RishiSync`, and `RishiChat` packages.

The audit produced 17 findings split into P0 (presentation traps, all migrated in plans 18-01..18-06), P1 (pragmatic deviations, mixed migrate/keep across 18-02..18-08), and P2 (stylistic, mixed). Six findings migrated to native SwiftUI patterns; the five entries below are **kept deviations** — patterns that look non-idiomatic at first glance but have a defensible rationale documented in this ADR.

Future contributors: please do NOT reflexively migrate these without re-reading the rationale and confirming the constraint still applies.

## Format

Each entry below contains:

- **Finding ID** — back-link to `18-RESEARCH.md`.
- **Decision** — what we chose and why we kept it.
- **Why (Constraint)** — the specific technical constraint that blocks the native alternative.
- **Evidence** — file:line citations from the audit.
- **Trigger for revisit** — the conditions under which this decision should be re-evaluated.

---

## Deviation 1 — Hand-rolled gesture interleaving over PDFKit + Readium (F-P1-03)

**Decision:** Keep `ReaderTapRegionResolver` (pure value-typed resolver mapping tap location to `.previousPage / .toggleChrome / .nextPage`) and the `.simultaneousGesture(TapGesture()...)` overlay wiring atop the Readium `EPUBNavigatorViewController` (UIViewController) and `PDFKit.PDFView` (UIKit). Do NOT migrate to `TabView(.page)` + `.onTapGesture`.

**Why (Constraint):** The native SwiftUI paging idiom (`TabView` with `.tabViewStyle(.page)` plus `.onTapGesture` on each page) requires SwiftUI to own the scroll view. We do not — PDFKit owns its own internal `UIScrollView` and forwards taps via `PDFView` delegate methods; Readium delegates touches to a `WKWebView` which has its own selection lifecycle (text selection, link tap, double-tap-to-define). SwiftUI's native gesture system cannot interleave with either engine's scroll/selection state machine without re-implementing both engines from scratch. The pure resolver is good (Sendable, fully testable, no UIKit dependency); the gesture wiring is the unavoidable fragility, and is the leaf risk surfaced by the original reader-trap incident. With F-P0-01 now landed (NavigationStack migration in plan 18-01), the system chevron is the always-on backstop if the tap-to-show-chrome ever regresses again. Commit `dbc1c7d6d` is the engine-coexistence fix that proved the trade-off acceptable.

**Evidence:**

- `apps/apple/Packages/RishiReader/Sources/RishiReader/UI/ReaderTapRegionResolver.swift` (entire file — pure resolver).
- `apps/apple/Packages/RishiReader/Sources/RishiReader/UI/EPUBReaderScreen.swift` — `.simultaneousGesture(TapGesture()...)` overlay on the Readium UIViewControllerRepresentable.
- `apps/apple/Packages/RishiReader/Sources/RishiReader/UI/PDFReaderScreen.swift` — same overlay pattern on the PDFKit UIViewRepresentable.
- Commit `dbc1c7d6d` — engine-coexistence reader-chrome fix.
- 18-RESEARCH.md lines 124-132.

**Trigger for revisit:** Re-evaluate if any of the following land:
1. A future SwiftUI paging engine (hypothetical `PaginatedScrollView`) ships that accepts `UIViewRepresentable` / `UIViewControllerRepresentable` children and forwards taps cleanly to a SwiftUI gesture chain.
2. Readium ships a pure-SwiftUI navigator (currently UIKit-only as of Readium 3.9).
3. PDFKit exposes a SwiftUI wrapper that owns scroll behavior in a way SwiftUI gestures can compose with.

Until then, the resolver + `.simultaneousGesture` overlay is the correct pragmatic seam.

---

## Deviation 2 — Mac menu-bar intent dispatch via `NotificationCenter` (F-P1-07)

**Decision:** Keep `NotificationCenter.default.post(name:)` as the seam for routing Mac menu-bar commands (`Cmd+I` import book, `Cmd+F` search, etc.) into views that live inside SwiftPM packages. Five distinct `Notification.Name`s are posted from the app target's `RootView.consumePendingMacIntent()`; receivers live in `RishiLibrary` and `RishiReader` packages. Do NOT migrate to `@FocusedValue` / `@FocusedBinding`.

**Why (Constraint):** SwiftUI 17's `CommandsBuilder` plus `@FocusedValue` / `@FocusedBinding` is the textbook idiom for menu-bar-to-view command routing without untyped notification names. It requires the focused view to publish the value, and requires the publisher and consumer to share a common `FocusedValueKey` type. In our architecture, the rishi app target depends on the `RishiLibrary` and `RishiReader` packages — but those packages CANNOT import the rishi app target (one-way dependency, package boundary). `@FocusedValue` would force us to either (a) hoist the `FocusedValueKey` definitions into a shared package, fanning out coupling to every consumer, or (b) duplicate the keys at both ends, defeating the type-safety motivation. Additionally, our menu-bar intents apply regardless of which view is currently focused (e.g. `Cmd+I` should import a book whether the user is in the library, a reader, or the chat panel) — `@FocusedValue` is the wrong shape for "fan out to whichever receiver is mounted." NotificationCenter is the pragmatic fit, and the duplicate raw-string `Notification.Name("RishiCommand.importBook")` at `LibraryRootView.swift:106-117` is documented as a known coupling that must stay in sync (a sync test enforces this).

**Evidence:**

- `apps/apple/rishi/rishi/RootView.swift:365-422` — `consumePendingMacIntent()` posts five Notification.Names.
- `apps/apple/Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryRootView.swift:106-117` — `.onReceive(NotificationCenter.default.publisher(for:))` receivers.
- `apps/apple/Packages/RishiReader/Sources/RishiReader/UI/EPUBReaderScreen.swift:295-303` — additional receiver for in-reader menu commands.
- 18-RESEARCH.md lines 165-174.

**Trigger for revisit:** Re-evaluate if any of the following land:
1. Swift macro support lands for cross-target `@FocusedValueKey` declarations that don't require sharing a package (e.g. a `@FocusedValue` macro that synthesises a key from a string identifier).
2. The Mac menu-bar surface shrinks enough to be hosted entirely inside the app target (current scope is too large — TOC navigation, theme switching, read-aloud start/stop, etc. live in package code).
3. A future SwiftUI version makes `@FocusedValue` fan out to all mounted views regardless of focus state.

Until then, NotificationCenter with documented `Notification.Name` raw strings + a sync test is the correct seam.

---

## Deviation 3 — Settings presented as `.sheet` (F-P2-02)

**Decision:** Keep Settings as a `.sheet(isPresented: $showSettings)` over the library root, mounted from the library toolbar gear button. Do NOT migrate to a `NavigationLink` push from a "more" menu.

**Why (Constraint):** Apple itself is inconsistent — Books pushes Settings inside a more-menu navigation, Notes uses a sheet. We follow the Notes precedent because Settings is independent state (account, audio, sync, telemetry, billing management) where modality makes the return path obvious: dismiss-sheet returns the user exactly where they were. Pushing Settings would require introducing a more-menu intermediate screen on iPhone (no natural toolbar slot), and would orphan the iPad/Catalyst detail-pane logic (Settings as a pushed view inside NavigationSplitView's content column behaves badly — the user can navigate "into" Settings then "back" into a library item, which is conceptually confused). The sheet form factor also matches the existing Paywall sheet (Deviation 4 below) and the reader sub-sheets (TOC, typography, theme), giving a consistent modal-sheet vocabulary across the app.

**Evidence:**

- `apps/apple/rishi/rishi/RootView.swift:459-465` — `.sheet(isPresented: $showSettings)` mounting `SettingsSheet`.
- `apps/apple/Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryRootView.swift:68-76` — toolbar gear button triggering the binding.
- Apple Notes app (system reference) — Settings as sheet, not push.
- 18-RESEARCH.md lines 198-206.

**Trigger for revisit:** Re-evaluate if any of the following land:
1. User testing surfaces "I can't find Settings" or "I keep losing my place when closing Settings" complaints in v1.x feedback.
2. A Settings deep-link from the Mac menu bar lands (`Cmd+,`) and the sheet presentation interferes with macOS Settings window conventions.
3. The Settings surface grows to multiple top-level sections that warrant a `NavigationSplitView` of their own (currently a single-column form, well-suited to a sheet).

Until then, sheet is the correct form factor.

---

## Deviation 4 — Paywall presented as `.sheet` (F-P2-03)

**Decision:** Keep `PaywallView` mounted via `.sheet(item: $paywallFeature)`. Do NOT consider any alternative presentation.

**Why (Constraint):** Paywall is genuinely modal — the user cannot navigate away while a paywall is presented; the decision to Subscribe / Restore / Manage / Dismiss is an interruption-shaped flow by design. App Review Guideline 3.1.2 requires a visible disclosure block (subscription terms, auto-renewal, cancellation) plus a Manage Subscription affordance — all of which compose cleanly inside a `.sheet`. Any non-modal presentation (push, inline, banner) would either let the user bypass the disclosure or make the Subscribe button feel like a low-stakes secondary action, both of which create App Review risk. The `.sheet(item:)` form (vs `.sheet(isPresented:)`) also lets us drive WHICH paywall variant to show via the `PaywallFeature` enum payload (TTS, sync, voice chat each gate at the same surface).

This entry exists in the ADR ONLY to prevent reflexive migration. There is no native-SwiftUI alternative that improves on `.sheet(item:)` for a genuinely modal paywall.

**Evidence:**

- `apps/apple/rishi/rishi/RootView.swift:229-251` — `.sheet(item: $paywallFeature)` mounting `PaywallView`.
- `apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/PaywallView.swift` — App Review 3.1.2 disclosure + Manage Subscription link.
- App Review Guideline 3.1.2.
- 18-RESEARCH.md lines 208-216.

**Trigger for revisit:** Never under current App Review rules. The only conceivable trigger is a future App Review guideline change that mandates non-modal paywall presentation — unlikely, but documented for completeness.

---

## Deviation 5 — Legacy `@unchecked Sendable` patterns in `RishiSync` (F-P2-04)

**Decision:** Keep the eleven `public final class @unchecked Sendable` declarations in `apps/apple/Packages/RishiSync/Sources/` (`GRDBSyncMetadataStore`, all uploaders, all fetchers, `ChangeApplier`, `EngineHolder`, `SyncStatus`). Do NOT rewrite to default-isolation `MainActor` or actor-wrap any of them in Phase 18.

**Why (Constraint):** This is documented as an intentional pattern in `apps/apple/.planning/STATE.md` at the Phase 2 and Phase 7 decision entries (line ~141 of STATE.md: *"GRDB stores ship as `final class @unchecked Sendable` (not actors) — DatabaseQueue already serialises access; an outer actor would double-hop every read/write and break the synchronous `read { db in ... }` ergonomics"*). The pattern is correct for two distinct reasons that cannot both be satisfied by default-isolation MainActor:

1. **GRDB internals serialise via `DatabaseQueue`.** Wrapping a GRDB store in an actor would force every `read { db in ... }` closure through an extra actor hop, breaking the synchronous closure ergonomics that GRDB's API depends on. `@unchecked Sendable` is the right escape hatch: the lock is in the queue, not in Swift's actor system.
2. **URLSession callbacks are inherently nonisolated.** The uploaders / fetchers receive `URLSession` delegate / completion callbacks on URLSession's own queue. Marking them `@MainActor` would force every callback through a hop to main, which is wrong for background sync work.

Phase 18's scope is the UI surface (presentation, navigation, gestures, toolbars). Rewriting the entire RishiSync package to default-isolation would expand the Phase 18 budget by an estimated 2+ weeks for zero user-visible behavior change, and would risk introducing subtle data-race regressions in code that has shipped through Phase 7 (sync engine) and Phase 16 (D1 conversation sync) without incident. The locks are correct; the pattern is documented; rewriting is "improve, don't fix."

Compare to F-P1-06 (the TTS extension `@unchecked Sendable` boxes), which WAS migrated in plan 18-05 because access was main-actor-only — the boxes were unnecessary. The RishiSync classes are different: their `@unchecked Sendable` is load-bearing for the GRDB and URLSession integrations.

**Evidence:**

- `apps/apple/Packages/RishiSync/Sources/RishiSync/Stores/GRDBSyncMetadataStore.swift` — `final class @unchecked Sendable`.
- `apps/apple/Packages/RishiSync/Sources/RishiSync/Uploaders/*.swift` — all uploaders.
- `apps/apple/Packages/RishiSync/Sources/RishiSync/Fetchers/*.swift` — all fetchers.
- `apps/apple/Packages/RishiSync/Sources/RishiSync/Engine/ChangeApplier.swift`, `EngineHolder.swift`, `SyncStatus.swift`.
- `apps/apple/.planning/STATE.md` line ~141 (Phase 2 GRDB decision).
- `apps/apple/.planning/STATE.md` line ~152 (Phase 3 KeychainBackend `OSAllocatedUnfairLock` precedent — same lock-not-actor rationale).
- Commit `4bffec8f8` — `AppChatRefreshAdapter` `@unchecked Sendable` REMOVAL, the contrasting case (main-actor-only access, plan 18-05 / F-P1-06).
- 18-RESEARCH.md lines 218-226.

**Trigger for revisit:** Re-evaluate when ALL of the following are true:
1. A future Phase explicitly budgets a full Swift 6 strict-concurrency audit of `RishiSync` (estimated 2+ weeks; track as v1.1 follow-up).
2. GRDB ships a Swift Concurrency-native API that removes the synchronous closure ergonomics dependency.
3. URLSession async/await APIs cover 100% of the delegate/callback surface we use today (currently true for `data(for:)` but not for resumable upload tasks).

Until then, keep the `@unchecked Sendable` pattern and the locks they imply.

---

## Related Phase-18 cleanups (NOT in this ADR)

For clarity, the following Phase 18 findings DID land as migrations (so future readers do not conflate them with the kept deviations above):

- **F-P0-01..06** — Reader presentation migrated from `.fullScreenCover` to `NavigationStack`. Plan 18-01.
- **F-P1-01** — Haptic feedback migrated to `.sensoryFeedback(_:trigger:)`. Plan 18-02.
- **F-P1-02** — Dead `PageTurnAnimator` / `PageTurnGestureResolver` / `ReaderPageTransitionResolver` infrastructure deleted. Plan 18-03.
- **F-P1-04** — `NavigationSplitView` auto-collapse on Catalyst via `.navigationSplitViewStyle(.balanced)`. Plan 18-04.
- **F-P1-05** — `EPUBReaderToolbar` / `PDFReaderToolbar` hand-rolled overlays migrated to native `.toolbar { ToolbarItemGroup }`. Plan 18-07.
- **F-P1-06** — TTS reader extension `@unchecked Sendable` boxes removed (main-actor-only access). Plan 18-05.
- **F-P1-08** — Dead SwiftData scaffolding (`ContentView.swift` + `Item.swift`) from the Xcode template deleted. Plan 18-06.
- **F-P2-01** — Reader sheets collapsed into a single `ReaderSheet?` enum + `.sheet(item:)`. Plan 18-08.

## How to use this document

**For future PRs that touch any of the five areas above:**

1. Before adding a non-native pattern in `RishiReader` gesture wiring, the Mac menu-bar dispatch, Settings/Paywall presentation, or `RishiSync` Sendable surface — re-read the relevant entry here and confirm the constraint still applies.
2. If the constraint no longer applies (one of the revisit triggers has landed), open a planning doc to migrate, link it back to this ADR, and update or supersede the entry.
3. If you discover a NEW non-native deviation outside the five entries above and decide to keep it, ADD a new entry to this ADR with the same structure (Decision / Why / Evidence / Revisit). Do not let kept deviations accumulate undocumented.

**For future native-SwiftUI audits:**

1. Audits subsequent to Phase 18 should start by re-validating each entry here — confirm the constraint still holds, update the revisit conditions if the SwiftUI surface has evolved.
2. New audits produce their own RESEARCH.md and may produce their own ADR if new categories of kept-deviation emerge. Link siblings here in a "Related ADRs" section.

## Sources

- `apps/apple/.planning/phases/18-native-swiftui-audit-and-migration-sweep-for-the-ios-app/18-RESEARCH.md` — audit findings F-P1-03, F-P1-07, F-P2-02, F-P2-03, F-P2-04.
- `apps/apple/.planning/STATE.md` — Accumulated Decisions section (Phase 2 GRDB, Phase 3 Keychain, Phase 3 SIWA, Phase 18 reader-chrome).
- Commit `dbc1c7d6d` — engine-coexistence reader-chrome fix referenced by F-P1-03.
- Commit `4bffec8f8` — `AppChatRefreshAdapter` `@unchecked Sendable` removal, the contrasting case for F-P2-04.
- App Review Guideline 3.1.2 — subscription disclosure requirement (F-P2-03).

## Document conventions

- Add new entries here ONLY for kept-deviations, not for closed migrations.
- Each entry MUST have all four fields: Decision, Why, Evidence, Trigger for revisit.
- Evidence MUST cite file:line, not just file paths.
- When opening a new ADR after a future audit, copy this format and link back to that audit's RESEARCH.md.
