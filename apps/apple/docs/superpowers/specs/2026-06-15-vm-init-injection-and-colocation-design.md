# View-Model Init-Injection + RishiLibrary Colocation

**Date:** 2026-06-15
**Status:** Approved (design); proceeding autonomously per user (no spec-review pause).
**Scope:** `apps/apple/rishi/rishi/` host views + `apps/apple/Packages/RishiLibrary/`. Other packages out of scope.

## Problem

Two consistency/readability issues remain after the SignedInView decomposition:

1. **VM construction lives inside the view.** Host views build their `@Observable` view model from `services` in their own `init` (e.g. `PaywallHost`, `ConversationChatHost`, `PDFReaderDestination` do `_vm = State(initialValue: VM(services...))`). That couples each view to service wiring, so it cannot be driven in a `#Preview` or unit-tested with a stub VM. Meanwhile `LibraryRootView` uses the opposite, implicit pattern (`@Environment(LibraryViewModel.self)`). The patterns are inconsistent and neither is ideal: one over-couples, the other hides the dependency.

2. **`LibraryViewModel` is split from its views.** In `RishiLibrary` the view model sits in `ViewModel/LibraryViewModel.swift` while its views live in `Views/`, so the view+VM pair is not colocated.

## Goal

- **Init-injection:** a view that renders a feature *receives* its `@Observable` VM as a `let` init parameter and observes it; it does not construct the VM from `services`. Construction moves to thin per-feature factories. Result: views are previewable/testable with stub VMs, and the dependency is explicit (no hidden environment lookup at feature boundaries).
- **Colocation:** `LibraryViewModel` sits beside its views.

Behavior-preserving. See [[feedback_apple_layering_discipline]]. Imports verified each step with the explicit-modules build (see [[reference_apple_explicit_modules_imports]]).

## Non-Goals

- No change to other packages' folder layout (only RishiLibrary).
- No engine changes; no default-isolation flip.
- `SignedInViewModel` stays `@State`-owned by `SignedInView` — it is the shell's owner, not an injected leaf.

## Design

### Part A — Init-injected view models

**The pattern.** A view receives `let vm: SomeViewModel` and observes it (Observation tracks `@Observable` access through a plain `let`; use a local `@Bindable var vm = vm` in `body` only where a two-way `$vm.x` binding is needed). When the view must retain the VM across its own recomputes (sheet/destination content), it seeds `@State` from the injected value:
```swift
@State private var vm: SomeViewModel
init(vm: SomeViewModel, /* other params */) { _vm = State(initialValue: vm) }
```
This is "inject the initial value into `@State`": the caller supplies a built VM; `@State` only keeps it alive. The view no longer knows how to build it.

**Factories.** VM construction moves to a thin per-feature factory, colocated with the feature. Use `static func make(...)` on the VM type in an app-target file (e.g. `Billing/PaywallViewModel+Make.swift`) or a small `…ViewModelFactory`:
- `PaywallViewModel.make(services:)`
- `ConversationsListViewModel.make(services:)`
- `ChatPanelViewModel.make(conversation:services:)`
- `PDFReaderViewModel.make(book:userId:services:)`, `EPUBReaderViewModel.make(book:userId:services:)`
- `LibraryViewModel.make(services:user:)`

**Per-view changes:**
- `PaywallHost`: take `let vm` (seed `@State`); caller (`SignedInView` paywall sheet) builds via `PaywallViewModel.make(services:)`.
- `ConversationChatHost`: take `let vm` (seed `@State`); caller builds via `ChatPanelViewModel.make(conversation:services:)`.
- `ConversationsListHost`: take `let vm`; caller builds via `ConversationsListViewModel.make(services:)`.
- `PDFReaderDestination` / `EPUBReaderDestination`: take `let vm` (the reader VM); `ReaderDestinationView` (which already has the resolved `Book`) builds via the factory and passes it. The destinations keep owning their `ReadAloudController?` and position-sync binding as `@State` — only the VM construction moves out.
- `LibraryRootView`: replace `@Environment(LibraryViewModel.self)` with an injected `let viewModel` parameter on BOTH public inits; `LibraryTabView` builds via `LibraryViewModel.make(services:user:)` and passes it, dropping `.environment(libraryVM)`. (Confirmed: `LibraryRootView` is the only reader of that environment value, so no cascade.)
- **Exception:** `ChatPanelHostView` (book-chat entry) builds its VM only after an async `conversationLookup.findOrCreate`, so it cannot receive a VM that does not exist yet. It keeps constructing in `.task`, but via `ChatPanelViewModel.make(conversation:services:)` so construction stays centralized in the factory.

### Part B — Flatten RishiLibrary

Move `Sources/RishiLibrary/ViewModel/LibraryViewModel.swift` into `Sources/RishiLibrary/Views/` (beside `LibraryRootView.swift`), and remove the now-empty `ViewModel/` folder. Folder keeps the name `Views/`. The lower layers (`Storage/`, `Import/`, `Indexing/`, `Search/`, `Models/`) are unchanged — they are service/model, not the view+VM pair being colocated. The package's test folder `Tests/RishiLibraryTests/ViewModel/` is untouched (it references symbols, not source paths). This is a pure intra-package file move; SwiftPM globs by directory so the module is unchanged.

## Execution Strategy — incremental, explicit-modules gated

Each step its own commit; the MAIN orchestrator runs the explicit-modules build after each:
`xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' build SWIFT_ENABLE_EXPLICIT_MODULES=YES` (and `... test` at the end).

1. Add the factory `make(...)` functions (no call-site changes yet).
2. Convert Billing + Chat hosts to init-injection (`PaywallHost`, `ConversationsListHost`, `ConversationChatHost`; route `ChatPanelHostView` through the factory).
3. Convert the reader destinations to init-injection (`ReaderDestinationView` builds the VM, passes to PDF/EPUB destinations).
4. Convert `LibraryRootView` to init-injection; update `LibraryTabView`; drop `.environment(libraryVM)`.
5. Flatten RishiLibrary (move `LibraryViewModel.swift` into `Views/`).

## Testing Strategy

- Safety net: existing app + package suites (baseline green). Stay green each step; explicit-modules build gate catches import regressions.
- Factories are trivial constructors — no new tests needed, but the resulting views are now stub-injectable, enabling future preview/tests.
- No mocking of engines; Swift Testing only.

## Risks & Mitigations

- **Seeding `@State` from an injected VM** can recreate the VM on caller recompute. Mitigation: the affected views are presented in sheets/destinations whose builder closures run per-presentation, so this is the same lifetime as today; `@State` ignores subsequent `initialValue`s, preserving stability. Verify reader "no stuck Opening" + TTS behavior after step 3.
- **`LibraryRootView` env→init conversion** could break a hidden consumer. Mitigation: grep-confirmed `LibraryRootView` is the sole `@Environment(LibraryViewModel.self)` reader; no re-injection needed.
- **RishiLibrary file move** could disturb the build. Mitigation: SwiftPM is path-agnostic within `Sources/`; run `swift test --package-path` + the explicit-modules gate.
