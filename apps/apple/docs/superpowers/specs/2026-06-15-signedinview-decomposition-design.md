# SignedInView Decomposition

**Date:** 2026-06-15
**Status:** Approved (design)
**Scope:** `apps/apple/rishi/rishi/` app-composition layer. Decompose the 678-line `SignedInView.swift` into focused, single-responsibility views and a thin shell viewModel, organized into the existing app-target feature folders. SwiftPM packages under `apps/apple/Packages/` are out of scope except incidental call-site updates.

## Problem

The prior refactor reduced `RootView` to a 222-line auth switch but moved the signed-in composition wholesale into `SignedInView.swift`, which is now itself a God file:

- 678 lines, **5 helper structs** crammed into one file (`GlassCardBackground`, `PaywallFeature`, `ReaderViewModelCache`, `NavigationLazyBook`, `EpubPlaceholderView`).
- **11 distinct concerns** mixed together: library tab, reader hosting (PDF/EPUB destinations, VM cache, position-sync bindings, read-aloud trigger, voice picker, controls overlay), three modal sheets (chat, paywall, settings), deep-link wiring, scene restore/persist, and Mac-command intent dispatch.
- **6 loose `@State` properties** spanning unrelated concerns (`readAloud`, `selectedConversation`, `paywallFeature`, `showSettings`, `bookHints`, `pdfSyncBinding`, `epubSyncBinding`, `readerVMCache`, `sceneRestored`).
- **6 `@ViewBuilder` helper methods** (`libraryTab`, `conversationsDestination`, `destinationView`, `pdfReaderDestination`, `epubReaderDestination`, `readAloudControlsOverlay`) that cannot own state, cannot be tested in isolation, and recompute with the whole parent.

## Goal

Apply the discipline established for `RootView` one level down: small, single-purpose views (one struct per file), a thin viewModel for the shell's presentation state, and feature-folder organization, so the signed-in composition is easy to read and testable.

Guiding rules for this pass:
- **One struct per file.**
- **Every `@ViewBuilder` helper method becomes its own `View` struct** in its feature folder. A `@ViewBuilder` method is a view that can't own state or be tested — promote it.
- **Each view owns the state it alone uses** (e.g. a reader destination owns its reader VM); cross-cutting modal state moves to a shell viewModel.
- Behavior-preserving. The existing test suite stays green at every step.

## Non-Goals

- No whole-app-target reorg (only `SignedInView`'s concerns this pass).
- No new SwiftPM packages; reuse existing app-target feature folders (`Reader/`, `Chat/`, `Billing/`, `Library/`, `Mac/`, `DeepLink/`).
- No engine changes; no flip of default-isolation = MainActor.

## Target Design

### A. One struct per file (move the helpers out of `SignedInView.swift`)
- `Reader/NavigationLazyBook.swift`
- `Reader/EpubPlaceholderView.swift`
- `Reader/GlassCardBackground.swift` (co-located with its only consumer, the read-aloud overlay)
- `Billing/PaywallFeature.swift`

(`ReaderViewModelCache` is intentionally NOT moved — it is deleted in step C once each reader destination owns its VM.)

### B. Promote every `@ViewBuilder` method to a `View` struct

| Current method | New file |
|---|---|
| `libraryTab(...)` | `Library/LibraryTabView.swift` — owns `libraryVM` (`@State`), the `NavigationStack`, the two `navigationDestination`s, the sample-installer `.task`, and the settings sheet trigger |
| `destinationView(for:)` | `Reader/ReaderDestinationView.swift` — the `ReaderRoute` switch + `NavigationLazyBook` resolution |
| `pdfReaderDestination(...)` | `Reader/PDFReaderDestination.swift` |
| `epubReaderDestination(...)` | `Reader/EPUBReaderDestination.swift` |
| `readAloudControlsOverlay(...)` | `Reader/ReadAloudControlsOverlay.swift` |
| `conversationsDestination(...)` | inlined at the call site (it is a one-line wrapper over the existing `ConversationsListHost`) |

After this, `SignedInView` and `LibraryTabView` contain **no `@ViewBuilder` helper methods**.

### C. Reader destinations own their own VM/controller/sync (eliminate `ReaderViewModelCache`)

`PDFReaderDestination` and `EPUBReaderDestination` each own, via `@State`:
- their reader VM (`PDFReaderViewModel` / `EPUBReaderViewModel`), constructed in `init` from the resolved `Book` + services;
- their `ReadAloudController?` (created on first Read-Aloud tap);
- their position-sync binding (`PDFReaderPositionSyncBinding` / `EPUBReaderPositionSyncBinding`).

Each renders its reader screen + `ReadAloudControlsOverlay` + voice-picker sheet, and bubbles the Read-Aloud entitlement gate up via an `onRequestPaywall: (String) -> Void` callback.

Because a `navigationDestination` view has stable identity within the nav stack, its `@State` survives parent body recomputes — which is exactly the bug `ReaderViewModelCache` was patching (a `@ViewBuilder` `let` VM was re-minted on every recompute, re-showing the stuck "Opening…" overlay and detaching TTS). Owning the VM as `@State` is the idiomatic form of the same fix, so **`ReaderViewModelCache` is deleted**. The behavior (no stuck overlay, TTS stays attached, position-sync still wired, drop-on-dismiss) must be preserved and verified.

### D. `SignedInViewModel` (`@MainActor @Observable`) for the shell's modal state

Holds the presentation state currently loose in `SignedInView`:
- `selectedConversation: Conversation?`
- `paywallFeature: PaywallFeature?`
- `showSettings: Bool`
- `bookHints: [BookID: Book]`

Children mutate it through intent methods (e.g. `requestPaywall(_ name: String)`, `present(conversation:)`, `hint(_ book:)`, `showSettings()`); `SignedInView` binds its sheets to it. This is the shell's missing **viewModel** layer and is unit-testable without SwiftUI. `libraryVM` is NOT part of this model — it moves down to `LibraryTabView` which owns it. `sceneRestored` is a private one-shot guard that stays with whichever view owns the scene-restore modifier (see E).

### E. Extract wiring into named view modifiers (one file each)
- `Mac/MacCommandDispatchModifier.swift` — `.macCommandDispatch(router:readerDefaults:onShowChats:)` wrapping the `consumePendingMacIntent` switch.
- `DeepLink/DeepLinkHandlingModifier.swift` — `.deepLinkHandling(router:services:model:libraryVM:)` wrapping the `.onOpenURL` callback wiring.
- `Mac/SceneRestorationModifier.swift` — `.sceneRestoration(router:services:tabRaw:openBookIdRaw:model:)` wrapping the restore `.task` (with its `sceneRestored` guard) and the persist `.onChange`.

These keep behavior identical; they exist to move ~120 lines of wiring out of the body into self-describing, individually-readable units.

### F. `SignedInView` becomes a lean composition root (~120-150 lines)

Owns the `SignedInViewModel` (`@State`), composes `LibraryTabView`, attaches the three sheets (bound to the model), and applies the three wiring modifiers. No reader state, no `@ViewBuilder` methods, no helper structs.

## Layering per feature folder

The model/service/viewModel layers already live in the SwiftPM packages. At the app-composition layer, each feature folder holds the **view** (host views, destinations) plus, where there is genuine shell logic, a thin **viewModel** (`SignedInViewModel`). This keeps the app target as composition glue while honoring view → viewModel → service → model. See [[feedback_apple_layering_discipline]].

## Execution Strategy — incremental (strangler), tests green each step

Ordered so each step is independently verifiable; `xcodebuild` gate after the reader extraction and at the end (the riskiest steps).

1. Move the 5 helper structs to their own files (pure move). Gate.
2. Extract `LibraryTabView` (owns `libraryVM`); `SignedInView` composes it. 
3. Extract `ReaderDestinationView` + `PDFReaderDestination` + `EPUBReaderDestination` + `ReadAloudControlsOverlay`; destinations own VM/controller/sync; delete `ReaderViewModelCache`. Gate (behavior-sensitive).
4. Introduce `SignedInViewModel`; move the 4 modal-state properties into it; wire children via intent methods + sheet bindings. Add unit tests for the model. Gate.
5. Extract the three wiring modifiers; `SignedInView` applies them. Gate.

## Testing Strategy

- **Safety net:** the existing app + package suites (baseline green). Must stay green after each step; the main orchestrator runs `xcodebuild ... test` at the gates (subagents may not run `xcodebuild`).
- **New unit tests** for `SignedInViewModel` (Swift Testing): intent methods set the right state (paywall feature, selected conversation, hint cache, settings flag), since it is now isolatable.
- View extractions are behavior-preserving; verified by per-file typecheck + the full suite. No unit tests for pure presentation views.
- **Manual smoke (post-implementation, main orchestrator notes it):** launch → open PDF + EPUB → Read Aloud across a page/chapter boundary (the eliminated-cache risk) → voice picker → chat → paywall gate → settings → deep link → background/restore.

## Risks & Mitigations

- **Eliminating `ReaderViewModelCache`** could reintroduce the stuck-"Opening…" / TTS-detach bug if `@State` identity is not stable. Mitigation: each destination owns its VM via `@State(initialValue:)` keyed by the route's stable identity; verify with the reader/TTS test suite and the manual smoke. If a regression appears, fall back to relocating the cache.
- **Modal state moving to `SignedInViewModel`** could change sheet timing if a binding is wrong. Mitigation: one step, bind sheets to the model with identical get/set semantics; lean on existing tests + smoke.
- **Wiring modifiers** could alter modifier order. Mitigation: preserve exact order; apply modifiers in the same sequence they appear today.
