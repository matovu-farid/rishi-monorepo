# RootView + Dependency-Injection Restructure

**Date:** 2026-06-15
**Status:** Approved (design)
**Scope:** `apps/apple/rishi/rishi/` app-integration layer only — `RootView.swift` and `AppDependencies.swift`. Package sources under `apps/apple/Packages/` are out of scope except for incidental call-site updates.

## Problem

The package layer (17 SwiftPM packages) is well-bounded, but the app-integration layer is tangled into two God files:

- `rishi/rishi/RootView.swift` — 1,275 lines, ~11 distinct responsibilities (auth gating, navigation/`NavigationPath`, reader sheet lifecycle, deep-link routing, scene restoration, read-aloud/TTS orchestration, chat/paywall/onboarding modal state, Mac command routing, library tab assembly).
- `rishi/rishi/AppDependencies.swift` — 1,256 lines, a two-phase bootstrap that builds 60+ services **and** every ViewModel, then exposes ~40 forwarder accessors and several VM factory methods.

ViewModels (`LibraryViewModel`, `ChatPanelViewModel`, `ConversationsListViewModel`, `PaywallViewModel`, `ReaderTTSBridge`) are treated as app-level dependencies built in the composition root, rather than being owned by the views that use them. This defeats local reasoning, forces integration-style tests, and makes every feature change touch the same two files.

## Goal

Establish and apply a strict **view → viewModel → service → model** discipline in the app-integration layer:

- **Views** own their ViewModels (via `@State`) and contain only presentation/composition.
- **ViewModels** receive only the **service protocols** they need — never the whole registry.
- **Services** depend on **models**.
- `AppDependencies` becomes a pure **service registry** — it vends services, it does not build or own ViewModels.

Behavior is preserved. The existing test suite must stay green at every step.

## Non-Goals

- No changes to package-internal architecture beyond call-site updates required by the moves above.
- No replacement of underlying engines (Readium, PDFKit, GRDB, Better Auth, StoreKit, AVFoundation).
- No flip of default-isolation = MainActor.
- The two-phase bootstrap (sync `init` + async `bootstrap`) is **retained** — it exists for first-frame launch performance, not as tangle.

## Target Design

### 1. `AppDependencies` → service-only registry

- **Remove** ViewModel concerns: `makeChatPanelViewModel(...)`, `makeConversationsListViewModel()`, `makePaywallViewModel()`, `makeReaderTTSBridge(...)`, and the `libraryViewModel` forwarder. ViewModels move to their owning views.
- **Retain** the two-phase bootstrap and the `services: BootstrappedServices?` publication model.
- **Split the file** by feature into extensions of the same type, so no single file is a God file:
  `AppDependencies.swift` (core type + bootstrap), `AppDependencies+Auth.swift`, `+Persistence.swift`, `+Sync.swift`, `+Chat.swift`, `+Audio.swift`, `+Billing.swift`, `+Library.swift`. (Exact split finalized during planning; principle: one feature group per file, each well under ~300 lines.)
- Services are still injected through the environment (`\.appDependencies`), but consumers reach for **specific service protocols**, not VM factories.

### 2. `RootView` → thin shell + extracted concern types

`RootView` shrinks to: gate on auth state (loading / signed-in / signed-out) and compose children. Each extracted concern becomes its own type:

- **`AppRouter`** (`@MainActor @Observable`): owns `NavigationPath` and `ReaderRoute`; routes deep links by delegating to the existing `DeepLink/DeepLinkRouter.swift`; coordinates persistence/restore by delegating to the existing `Mac/SceneRestorationState.swift`. The inline `.onOpenURL` decode chain and the 3-step scene-restoration decode chain move out of RootView and into these existing types via `AppRouter`.
- **`ReadAloudController`** (`@MainActor @Observable`): owns the `ReaderTTSBridge` plus passage/paragraph tracking state (the ~150 TTS lines currently in RootView).
- **Auth gating**: extracted into a small `SignedInView` (and the existing `SignedOutView` continues to handle the signed-out branch). RootView just switches between loading / `SignedInView` / `SignedOutView`.
- **Child hosts own their VMs via `@State`**:
  - `SignedInView` / library tab owns `LibraryViewModel`.
  - `ChatHost` owns `ChatPanelViewModel` / `ConversationsListViewModel`.
  - `PaywallHost` owns `PaywallViewModel`.
  - `OnboardingHost` owns its onboarding VM.
  Each host resolves the services it needs from the environment and constructs its VM locally.

### 3. Layering rule (applies to all touched code)

```
View  ──owns──▶  ViewModel  ──depends on──▶  Service (protocol)  ──▶  Model
```

A ViewModel never receives `AppDependencies`/`ServiceRegistry`; it receives the narrow service protocol(s) it actually uses. A View never calls a service directly; it goes through its ViewModel.

## Execution Strategy — incremental "strangler" (Approach A)

Move one concern at a time, each its own commit, running the relevant package/app tests after each step. Old and new patterns may briefly coexist; that is acceptable between steps.

Ordered steps:

1. **Lift VM ownership into views.** For each VM factory in `AppDependencies`, give the owning host view a `@State` VM constructed from environment services; delete the factory. One VM per commit (Library, Chat, Conversations, Paywall, ReaderTTS).
2. **Extract `ReadAloudController`** from RootView (TTS bridge + passage state).
3. **Extract `AppRouter`** and route deep-link + scene-restoration logic through the existing `DeepLinkRouter` / `SceneRestorationState`.
4. **Extract `SignedInView`** and the child hosts (`ChatHost`, `PaywallHost`, `OnboardingHost`); reduce `RootView` to the auth switch + composition.
5. **Slim & split `AppDependencies`** into the service-only registry plus per-feature extension files.

After every step: run the affected package tests (`swift test --package-path apps/apple/Packages/<Package>`) and/or app-target type-checks; the main orchestrator runs a full `xcodebuild` at the end as the integration gate.

## Testing Strategy

- **Safety net:** the existing suite is the regression oracle — baseline build/`build-for-testing` is green (verified 2026-06-15). It must stay green after each step.
- **Characterization tests** are added only where current coverage is thin around a concern being moved (notably scene restoration and read-aloud, which already have `RootViewSceneRestorationTests` and `ReaderTTS*` tests — extend if a move would otherwise go unguarded).
- New extracted types (`AppRouter`, `ReadAloudController`) get focused unit tests now that they are isolatable — this is a primary payoff of the restructure.
- Swift Testing only. No mocking of engines; use `RishiTesting` doubles.

## Risks & Mitigations

- **Hidden coupling via `@Environment`/`@Observable` re-render timing.** Mitigation: move one concern per commit, verify tests + a manual smoke of launch → library → open reader → read-aloud → chat → paywall after the structural steps.
- **Scene restoration / deep-link regressions** (logic is subtle). Mitigation: route through existing tested types rather than rewriting; lean on `RootViewSceneRestorationTests`.
- **Two-phase bootstrap breakage** affecting first-frame perf. Mitigation: do not touch the bootstrap timing; only remove VM construction from it.

## Out-of-scope follow-ups (noted, not done here)

The 300–800 line mixed-concern view files (`EPUBReaderScreen`, `PDFReaderScreen`, `PaywallView`, `LibraryRootView`) are candidates for the same discipline in a later pass, once the pattern is proven on RootView + DI.
