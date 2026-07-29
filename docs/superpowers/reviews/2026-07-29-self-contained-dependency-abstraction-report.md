# Self-Contained Dependencies Hidden Behind Abstraction Layers

> **Status:** Adversarial review loop complete — **PASS** (2 rounds, 0 open Critical/High issues)

## Executive summary

The strongest simplification opportunity is in the Apple application. Its feature areas are organized as `Rishi*` modules, but they are source folders inside one `rishi` Xcode target rather than independently buildable packages. The app composition root constructs a large object graph in `ServiceGraphFactory`, stores most of it in `BootstrappedServices`, and then exposes it again through `AppDependencies+*.swift` forwarding extensions.

This creates abstraction layers that do not hide meaningful implementation complexity. Several dependencies are self-contained or have exactly one production implementation, yet they are passed through factories, adapters, protocols, closures, and service-locator accessors. The code can be simplified without removing legitimate boundaries around StoreKit, Readium, WebRTC, persistence, or network transport.

The report's main conclusion is:

> The code has logical feature boundaries, but it is not currently dependency-self-contained. The Apple app remains a monolithic target with manual DI, duplicated configuration, global hooks, and several shallow forwarding layers.

## Scope and method

The review focused only on production source under `apps/apple/rishi/rishi`, its tests, and the Apple Xcode dependency declarations. It used call-site searches and independent repository scans. Generated `.build-*` directories and existing uncommitted work were excluded from conclusions.

“Simplify” means reducing pass-through layers where there is one implementation and no meaningful variability. It does not mean removing an adapter that owns a real platform or wire-format boundary.

## Findings at a glance

| Priority | Candidate | Evidence | Recommended direction |
|---|---|---|---|
| P0 | Sync engine constructor fan-out | `SyncEngine` accepts roughly 16 collaborators and reconstructs `OutboundDrainer` and `ChatInboundMerger` from the same graph | Group orchestration dependencies without hiding retry/order semantics |
| P0 | Apple composition root/service locator | `ServiceGraphFactory` plus `BootstrappedServices` exposes most of the application graph | Keep one composition root, but expose narrower feature capabilities |
| P1 | Explicit book materialization seam | `ChangeApplier` receives a closure wrapping `BookDownloadCoordinator` | Keep the seam; optionally name it with a small protocol and document ownership |
| P1 | Library view model graph leakage | `LibraryViewModel` receives storage, import coordinator, store, and position dependencies while constructing more helpers itself | Inject a narrow `LibraryOperations` capability or remove direct storage access |
| P1 | Chat lookup/store split | `RishiChatService` receives both `ConversationLookup` and its underlying `ConversationStore` | Make find-or-create part of chat persistence/service ownership |
| P1 | App forwarding extensions | Most are compatibility accessors over `services`; Billing also contains real sign-out/cache lifecycle behavior | Remove only pure accessors after capability migration |
| P1 | Dirty and refresh adapters | Adapters forward, but refresh registration also owns weak lifecycle and account safety | Retain typed delegates or replace with tokenized registration |
| P2 | `WorkerAPI` marker seam | Marker protocol has no methods but deliberately keeps testing from depending on the future API package | Keep/document; remove only with an explicit package-graph change |
| P2 | Duplicated runtime configuration | `RISHI_API_URL` is read in the app graph, worker endpoint, and billing service | Resolve configuration once at the composition root |
| P2 | Historical dependency terminology | GRDB, Stripe/BillingPortal, old package paths, and vendored dependency comments remain | Clean stale documentation and remove misleading seams |

## Detailed candidates

### 1. Sync engine constructor fan-out (P0)

`SyncEngine` accepts a large set of concrete collaborators, including the queue, metadata store, six uploaders, fetchers, and `ChangeApplier` ([`SyncEngine.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/SyncEngine.swift:82)). Its initializer then reconstructs `OutboundDrainer` ([`OutboundDrainer.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Engine/Outbound/OutboundDrainer.swift:41)) and `ChatInboundMerger` from much of the same graph. The uploaders are concrete and directly own the actual network/store work; for example, [`BookUploader.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Outbound/BookUploader.swift:20).

This is best described as constructor fan-out, not redundant behavior. `OutboundDrainer` owns meaningful per-kind bucketing, retry/re-enqueue policy, missing-book cleanup, batching, and error semantics. The problem is that the engine's constructor serializes the implementation graph and also rebuilds internal orchestration objects. There are no uploader protocols in `RishiSync`, so callers cannot meaningfully substitute the individual uploaders as a family.

Recommended simplification:

- Keep concrete uploader construction in `ServiceGraphFactory`.
- Give the engine one internal sync-runtime value or one `SyncOperations` capability that owns outbound dispatch.
- Avoid exposing the same queue/store/uploader graph through both engine and drainer.
- Preserve retry, ordering, cleanup, metrics, batching, and existing test seams.
- Include `ChatInboundMerger` in the graph inventory; do not collapse it without preserving inbound merge semantics.

Expected benefit: fewer constructor parameters, less duplicated wiring, and a boundary test for sync orchestration instead of tests that assemble the entire uploader graph.

### 2. Composition root and service locator (P0)

[`ServiceGraphFactory.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/ServiceGraphFactory.swift:25) constructs API, persistence, audio, library, sync, chat, voice, billing, and settings objects. [`BootstrappedServices`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/AppDependencies.swift:96) exposes those objects as a very large public-in-practice service locator. `AppDependencies` then provides bootstrap/lifecycle state and forwards selected fields through multiple extensions.

This is not a case for deleting the composition root. The root is the correct place to own platform and environment decisions. The issue is that every downstream caller can see the graph, so lower-level feature code is coupled to app-wide construction details.

Recommended simplification:

- Keep `AppDependencies` responsible for bootstrap and lifecycle.
- Group services by feature capability (`LibraryRuntime`, `SyncRuntime`, `ChatRuntime`, etc.) rather than exposing every leaf object.
- Make feature views consume only the capability they need.
- Remove the forwarding extensions once call sites use the capability groups consistently.

### 3. Explicit book materialization seam (P1)

The app builds [`BookDownloadCoordinator.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Inbound/BookDownloadCoordinator.swift:12) from `WorkerClient` and `BookFileStorage`, then injects a closure around it into [`ChangeApplier.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Inbound/ChangeApplier.swift:36).

The closure is a legitimate dependency boundary: `BookDownloadCoordinator` owns Worker/API, URL-session, identity, and file-storage concerns, while `ChangeApplier` owns generic change application. The review found one materializer, not duplicated materialization behavior.

Recommended simplification: keep the closure, or name it with a small `BookMaterializer` protocol in the sync/core boundary while retaining the app-layer adapter. Keep generic change ordering, conflict, and account checks in `ChangeApplier`.

### 4. Library view model receives both capabilities and implementation details (P1)

[`LibraryViewModel.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Views/LibraryViewModel.swift:64) receives `BookStore`, concrete `BookFileStorage`, `ImportCoordinator`, and position-loading dependencies, while also constructing `BookCoverResolver` from the same storage. `ImportCoordinator` itself wraps that storage ([`ImportCoordinator.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/Import/ImportCoordinator.swift:28)).

This makes the view model know both the library API and some assembly rules. `PositionLoader` and `BookCoverResolver` are created only when optional collaborators are absent; direct storage use is primarily for the default cover resolver. The production graph and tests still repeat some storage/coordinator construction.

Recommended simplification: inject a narrow library capability that owns importing, covers, and position-aware book presentation, or at minimum remove the view model's direct storage dependency and inject the already-composed cover/import capabilities.

### 5. Chat service and conversation lookup (P1)

[`ConversationLookup.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiChat/RishiChat/Storage/ConversationLookup.swift:12) wraps `ConversationStore` for find-or-create behavior. [`RishiChat_ChatService.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiChat/RishiChat/Service/RishiChat_ChatService.swift:23) receives both the lookup object and the underlying store, alongside message storage, `WorkerClient`, identity, and a dirty hook.

The lookup object owns find-or-create isolation, while `RishiChatService` separately uses `ConversationStore` to bump conversation metadata after messages. `VoiceSessionPresenter` also consumes the lookup, message store, and dirty hook. The safe simplification is a combined `ChatPersistence` capability with explicit `findOrCreate` and `bump` operations, not deletion of the underlying store dependency. Preserve concurrency and cancellation behavior.

### 6. App forwarding extensions (P1)

The `AppDependencies+Auth`, `+Audio`, `+Persistence`, `+Sync`, `+Chat`, and `+Settings` files mostly expose `services!.x` properties and appear to be compatibility surface; most production code accesses `services` directly. `AppDependencies+Billing.swift` also contains non-forwarding sign-out/cache lifecycle behavior.

Recommended simplification: standardize on feature capability groups. Delete only pure forwarding accessors after a call-site audit; preserve and separately test billing methods such as entitlement clearing, sync reset, metadata reset, and user-box mutation. Do not change bootstrap lifecycle semantics in the same change.

### 7. Dirty/refresh adapters (P1)

[`AppVoiceDirtyAdapter.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Voice/AppVoiceDirtyAdapter.swift:7) implements chat and voice dirty hooks by forwarding to `SyncEngine`. It is constructed once in the composition root and has no alternate production implementation. [`AppChatRefreshAdapter.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Chat/AppChatRefreshAdapter.swift:9) similarly stores one active chat view model/user ID and forwards refreshes.

The stateful activation/deactivation behavior of the chat refresh path is meaningful: it uses weak ownership and tracks the active user to avoid refreshing stale UI. Retain typed delegates, or replace them only with a tokenized registration API that has clear/replace semantics, weak ownership, and account-switch tests. The protocol/class shell is a possible simplification, not a free deletion.

### 8. `WorkerAPI` marker seam (P2)

[`WorkerAPI.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/Protocols/WorkerAPI.swift:3) has no methods, but it deliberately keeps `RishiTesting` from depending on the future API package. Keep it and document its ownership, or remove it only as part of an explicit `RishiTesting` → `RishiAPI` dependency change.

## Dependencies that should remain layered

These are not good simplification targets based on this review:

- `RealtimeClientAPI` / `RealtimeAPIAdapter`: a genuine SDK boundary with multiple test fakes.
- `Connector`: supports distinct WebRTC and WebSocket implementations.
- StoreKit receipt verification and entitlement synchronization: ordering and failure semantics are business-critical.
- Readium, ZIPFoundation, PDFKit, AVFoundation, MediaPlayer, Sentry, USearch, and WebRTC adapters: real platform or external-library boundaries.
- Persistence protocols used by reader and sync tests: these represent a meaningful storage boundary even if some individual store implementations are simple.

## Legacy dependency and configuration drift

- Current database code and smoke tests use SwiftData, but module comments still refer to GRDB ([`RishiChat.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiChat/RishiChat/RishiChat.swift:13), [`RishiLibrary.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiLibrary/RishiLibrary/RishiLibrary.swift:7)).
- Billing retains Stripe/BillingPortal terminology although current purchase flow is StoreKit ([`RishiBilling.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/RishiBilling.swift:4)).
- Plans and comments refer to an old `apps/apple/Packages` layout while implementation lives under `apps/apple/rishi/rishi/Modules`.
- `RISHI_API_URL` is read in the service graph, worker endpoint, and billing default client ([`ServiceGraphFactory.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/ServiceGraphFactory.swift:36), [`WorkerEndpoint.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiCore/RishiCore/RishiAPI/WorkerEndpoint.swift:35), [`PurchaseService.swift`](/Users/faridmatovu/projects/rishi-monorepo/apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/PurchaseService.swift:125)). `VoiceSessionPresenter` also has a separate hard-coded default URL. Centralization must preserve injected-client precedence and endpoint fallback behavior.
- The vendored `swift-realtime-openai` dependency has comments describing a pinned remote SHA, while the Xcode project uses the vendored source; ownership and update policy should be explicit.

## Suggested refactor order

1. Inventory constructors, direct `services.*` consumers, `ChatInboundMerger`, `VoiceSessionPresenter`, and `bookmarkUploader`; centralize immutable configuration while preserving injected-client precedence.
2. Design capability boundaries for sync, library, and chat before removing any forwarding accessors.
3. Migrate call sites to the capability boundaries, then delete only pure `AppDependencies+*.swift` accessors. Keep billing lifecycle methods separate.
4. Reduce `SyncEngine` constructor fan-out while preserving outbound retry/order/cleanup and inbound merge behavior.
5. Clarify the book materializer seam; do not move ownership without a boundary test.
6. Address stale terminology and decide separately whether global hooks/singletons need lifecycle cleanup.

## Verification needed before implementation

- Enumerate every `SyncEngine`, `LibraryViewModel`, `RishiChatService`, `AppDependencies`, `ChatInboundMerger`, `VoiceSessionPresenter`, `RootView`, and direct `services.*` call site in production and tests; include `bookmarkUploader` even though it has no forwarding accessor.
- Confirm whether any hidden test or preview relies on direct `BootstrappedServices` leaf access.
- Add boundary tests before collapsing sync, chat, or library construction.
- Verify sign-out, account switching, foreground refresh, background sync, and app relaunch after any graph/lifecycle change. In particular, test account switching during an upload: generation/cancellation must be checked before and after outbound side effects, or reset must cancel and await the active wave.
- Treat global hook cleanup as a separate change from constructor simplification.

## Adversarial review loop

Each round: review → log findings → update report → re-review.

### Round 1 — independent review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | “Self-contained dependencies” was too broad: the Apple feature folders are not independently buildable packages. | Report now states the monolithic Xcode-target limitation and distinguishes logical boundaries from build boundaries. |
| 2 | High | A constructor-only review would miss global state and duplicated environment reads. | Added global hooks/singletons and `RISHI_API_URL` duplication to findings and verification work. |
| 3 | Medium | Some adapters are real platform or wire boundaries and should not be collapsed. | Added explicit exclusions for StoreKit, Readium, WebRTC, and persistence boundaries. |

**Round 1 result:** Re-review required for artifact wording and candidate prioritization.

### Round 2 — re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Sync drainer, chat lookup/store, materialization, and refresh adapters each contain meaningful behavior or safety semantics; a blanket collapse would regress behavior. | Reclassified sync as constructor fan-out, kept materialization as a seam, specified a `ChatPersistence` facade rather than deleting stores, and retained typed/tokenized refresh registration with account-safety tests. |
| 2 | High | Billing forwarding extensions include sign-out/cache lifecycle behavior, and direct call-site coverage was overstated. | Limited removal to pure accessors and expanded the call-site audit to billing lifecycle methods, `RootView`, `VoiceSessionPresenter`, `ChatInboundMerger`, and `bookmarkUploader`. |
| 3 | High | Account switching can race with an active outbound wave. | Added an explicit before/after side-effect cancellation/generation requirement and a test scenario. |
| 4 | Medium | Source references and configuration recommendations needed more precise wording. | Corrected constructor line references, added `ChatInboundMerger` and voice URL fallback, and preserved injected-client precedence. |

**Round 2 result:** PASS — 0 open Critical/High issues. Remaining work is implementation planning, not a report defect.
