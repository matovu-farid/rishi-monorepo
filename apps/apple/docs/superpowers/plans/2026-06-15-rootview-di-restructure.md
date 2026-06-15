# RootView + DI Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Untangle the app-integration layer so `RootView` becomes a thin auth-switch shell and `AppDependencies` becomes a service-only registry, enforcing view → viewModel → service → model, without changing behavior or breaking tests.

**Architecture:** Incremental "strangler" refactor. ViewModels move out of `AppDependencies` into host views that own them via `@State`. RootView's non-view concerns are extracted into focused types (`AppRouter`, `ReadAloudController`) plus per-feature host views. `AppDependencies` keeps its two-phase bootstrap but drops all VM factories and is split into per-feature extension files.

**Tech Stack:** Swift 6 (strict concurrency, default-isolation = MainActor), SwiftUI, Swift Testing, SwiftPM packages + `rishi.xcodeproj` app target.

---

## Conventions & Build/Test Rules (read first)

- **Swift Testing only.** No XCTest, no emojis, no mocking of engines — use `RishiTesting` doubles.
- **App-target sources** (`apps/apple/rishi/rishi/`) are NOT in a SwiftPM package; their tests live in `apps/apple/rishi/rishiTests/` and only run under `xcodebuild`.
- **Subagents MUST NOT run `xcodebuild rishi`** (watchdog stalls). A subagent verifies a touched app-target file with:
  `xcrun --sdk iphonesimulator swiftc -typecheck <file>` (best-effort; cross-file deps may not resolve — that's expected, treat clean parse + signature match as the local gate).
- **The MAIN orchestrator runs the real red/green gate** for app-target tests:
  `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' test`
  Run it after each task group (and at minimum after Tasks 3, 5, 6, 9). This is the canonical "tests still green" checkpoint.
- **Package tests** (when a package source is touched) run with:
  `swift test --package-path apps/apple/Packages/<Package>`
- **Commit scope:** only under `apps/apple/{Packages,rishi,scripts,fastlane,docs}`. Never `.planning/`.
- **Baseline:** `build-for-testing` was green on 2026-06-15 — that is our regression oracle.

## File Structure

**New files (app target):**
- `rishi/rishi/App/AppRouter.swift` — `@MainActor @Observable` owner of `NavigationPath`, `ReaderRoute` selection, deep-link routing (via `DeepLinkRouter`), and scene persist/restore (via `RishiSceneState`).
- `rishi/rishi/Audio/ReadAloudController.swift` — `@MainActor @Observable` owner of `ReaderTTSBridge` + read-aloud paragraph/passage state and start/stop logic.
- `rishi/rishi/Views/SignedInView.swift` — authenticated shell; owns `LibraryViewModel` via `@State`; composes library tab + hosts.
- `rishi/rishi/Chat/ChatHost.swift` — owns `ChatPanelViewModel` / `ConversationsListViewModel` via `@State`.
- `rishi/rishi/Billing/PaywallHost.swift` — owns `PaywallViewModel` via `@State`.
- `rishi/rishi/Onboarding/OnboardingHost.swift` — owns the onboarding presentation; built from `onboardingState` / `onboardingCoordinator` services.

**New tests (`rishi/rishiTests/`):**
- `AppRouterTests.swift`
- `ReadAloudControllerTests.swift`

**Modified:**
- `rishi/rishi/RootView.swift` — shrinks to auth switch + composition; loses VM access, TTS state, navigation/scene/deep-link logic.
- `rishi/rishi/AppDependencies.swift` — remove VM factories + `libraryViewModel` accessor; split into extensions.
- `rishi/rishi/rishiApp.swift` — inject `AppRouter` into the environment.
- New env key files: `AppDependencies` split into `AppDependencies+Auth.swift`, `+Persistence.swift`, `+Sync.swift`, `+Chat.swift`, `+Audio.swift`, `+Billing.swift`, `+Library.swift` (the core type + bootstrap stays in `AppDependencies.swift`).

---

## STEP 1 — Lift ViewModel ownership into host views

> Each task removes one VM factory from `AppDependencies` and gives the owning view a `@State`-owned VM constructed from services. The SwiftUI pattern for "VM needs injected services" is constructor-injected `@State`:
> ```swift
> @State private var vm: SomeViewModel
> init(services: BootstrappedServices) {
>     _vm = State(initialValue: SomeViewModel(/* services */))
> }
> ```
> Verification for view-only moves: per-file `swiftc -typecheck` by the executor, then the MAIN orchestrator runs the full `xcodebuild ... test` at the end of the step. There is no new unit test for a pure presentation move — the existing suite + build is the oracle.

### Task 1: Paywall — view owns `PaywallViewModel`

**Files:**
- Create: `rishi/rishi/Billing/PaywallHost.swift`
- Modify: `rishi/rishi/RootView.swift` (paywall sheet presentation, currently keyed on `paywallFeature`)
- Modify: `rishi/rishi/AppDependencies.swift` (remove `makePaywallViewModel()`, lines ~852–861)

- [ ] **Step 1: Create `PaywallHost` owning the VM**

```swift
import SwiftUI
import RishiBilling

struct PaywallHost: View {
    let feature: PaywallFeature
    let onDismiss: () -> Void
    @State private var vm: PaywallViewModel

    init(feature: PaywallFeature, services: BootstrappedServices, onDismiss: @escaping () -> Void) {
        self.feature = feature
        self.onDismiss = onDismiss
        _vm = State(initialValue: PaywallViewModel(
            productService: services.storeKitProductService,
            purchaseService: services.purchaseService,
            restoreService: services.restoreService,
            managePresenter: services.manageSubscriptionPresenter
        ))
    }

    var body: some View {
        PaywallView(viewModel: vm, feature: feature, onDismiss: onDismiss)
    }
}
```
> NOTE: confirm `PaywallView`'s real initializer parameter labels while implementing (open `Packages/RishiBilling/Sources/RishiBilling/UI/PaywallView.swift`) and match them exactly; adjust the `body` line accordingly.

- [ ] **Step 2: Rewire RootView's paywall sheet** — replace the closure that called `deps.makePaywallViewModel()` with `PaywallHost(feature: feature, services: services, onDismiss: { paywallFeature = nil })`. Use the `services` value already guard-unwrapped in `realBodyContent`.

- [ ] **Step 3: Delete the factory** — remove `makePaywallViewModel()` from `AppDependencies.swift`.

- [ ] **Step 4: Typecheck** — Run: `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Billing/PaywallHost.swift` (expect clean parse; unresolved cross-module symbols are acceptable here).

- [ ] **Step 5: Commit**

```bash
git add rishi/rishi/Billing/PaywallHost.swift rishi/rishi/RootView.swift rishi/rishi/AppDependencies.swift
git commit -m "refactor(apple): PaywallHost owns PaywallViewModel; drop factory"
```

### Task 2: Conversations list — host owns `ConversationsListViewModel`

**Files:**
- Create/modify host in `rishi/rishi/Chat/ChatHost.swift` (create file; this task adds the conversations list piece)
- Modify: `rishi/rishi/RootView.swift` (`conversationsDestination(deps:user:)`, lines ~702–716)
- Modify: `rishi/rishi/AppDependencies.swift` (remove `makeConversationsListViewModel()`, lines ~901–906)

- [ ] **Step 1: Create `ChatHost.swift` with a conversations-list host**

```swift
import SwiftUI
import RishiChat

struct ConversationsListHost: View {
    let onOpenConversation: (Conversation) -> Void
    @State private var vm: ConversationsListViewModel

    init(services: BootstrappedServices, onOpenConversation: @escaping (Conversation) -> Void) {
        self.onOpenConversation = onOpenConversation
        _vm = State(initialValue: ConversationsListViewModel(
            conversationStore: services.conversationStore,
            messageStore: services.messageStore
        ))
    }

    var body: some View {
        ConversationsListView(viewModel: vm, onOpen: onOpenConversation)
    }
}
```
> NOTE: match the real `ConversationsListView` initializer labels from `Packages/RishiChat/Sources/RishiChat/UI/`; adjust `body`.

- [ ] **Step 2: Rewire `conversationsDestination`** in RootView to return `ConversationsListHost(services: services, onOpenConversation: { selectedConversation = $0 })` (mirror the existing callback wiring).

- [ ] **Step 3: Delete the factory** — remove `makeConversationsListViewModel()` from `AppDependencies.swift`.

- [ ] **Step 4: Typecheck** — `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Chat/ChatHost.swift`.

- [ ] **Step 5: Commit**

```bash
git add rishi/rishi/Chat/ChatHost.swift rishi/rishi/RootView.swift rishi/rishi/AppDependencies.swift
git commit -m "refactor(apple): ConversationsListHost owns its VM; drop factory"
```

### Task 3: Chat panel — host owns `ChatPanelViewModel` (both creation paths)

**Files:**
- Modify: `rishi/rishi/Chat/ChatHost.swift` (add `ChatPanelHostView`)
- Modify: `rishi/rishi/RootView.swift` (`presenterChatSheet(...)` lines ~722–754, and the in-reader chat creation in `libraryTab`/reader destinations)
- Modify: `rishi/rishi/AppDependencies.swift` (remove both `makeChatPanelViewModel` overloads, lines ~868–897; KEEP `conversationLookup` exposed as a service)

- [ ] **Step 1: Add a chat-panel host that resolves the conversation, then owns the VM**

```swift
struct ChatPanelHostView: View {
    let userId: UserID
    let bookId: BookID?
    let services: BootstrappedServices
    @State private var vm: ChatPanelViewModel?

    var body: some View {
        Group {
            if let vm {
                ChatPanelView(viewModel: vm)   // match real label
            } else {
                ProgressView()
            }
        }
        .task {
            guard vm == nil else { return }
            if let convo = try? await services.conversationLookup.findOrCreate(userId: userId, bookId: bookId) {
                vm = ChatPanelViewModel(
                    conversation: convo,
                    bookId: bookId,
                    chatService: services.chatService,
                    messageStore: services.messageStore
                )
            }
        }
    }
}

// For the already-have-a-conversation path (presenter sheet):
struct ConversationChatHost: View {
    @State private var vm: ChatPanelViewModel
    init(conversation: Conversation, services: BootstrappedServices) {
        _vm = State(initialValue: ChatPanelViewModel(
            conversation: conversation,
            bookId: conversation.bookId,
            chatService: services.chatService,
            messageStore: services.messageStore
        ))
    }
    var body: some View { ChatPanelView(viewModel: vm) }   // match real label
}
```

- [ ] **Step 2: Rewire `presenterChatSheet`** to use `ConversationChatHost(conversation:services:)` (was `deps.makeChatPanelViewModel(conversation:)`), and rewire the async book-chat entry point to `ChatPanelHostView(userId:bookId:services:)` (was the async `deps.makeChatPanelViewModel(userId:bookId:)`).

- [ ] **Step 3: Delete both factory overloads** from `AppDependencies.swift`.

- [ ] **Step 4: Typecheck** — `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Chat/ChatHost.swift`.

- [ ] **Step 5: MAIN orchestrator gate** — run the full `xcodebuild ... test`. Expected: PASS (all existing suites green). This is the Step-1 integration checkpoint.

- [ ] **Step 6: Commit**

```bash
git add rishi/rishi/Chat/ChatHost.swift rishi/rishi/RootView.swift rishi/rishi/AppDependencies.swift
git commit -m "refactor(apple): chat hosts own ChatPanelViewModel; drop factories"
```

### Task 4: Library — host owns `LibraryViewModel`

> `LibraryViewModel` is currently a stored property of `BootstrappedServices` (`let libraryViewModel: LibraryViewModel`) built during bootstrap, plus an `AppDependencies.libraryViewModel` forwarder. Move construction to the view; remove it from `BootstrappedServices` and the forwarder. It needs `bookStore`, `positionStore`, `bookFileStorage`, and a `currentUserId` closure — all available on `BootstrappedServices`.

**Files:**
- Modify: `rishi/rishi/Views/SignedInView.swift` (created in Task 7; if Task 4 runs first, temporarily own the VM in RootView's `libraryTab`. To avoid ordering coupling, **construct the VM in `SignedInView`** and run Task 7 before Task 4. See Step 0.)
- Modify: `rishi/rishi/AppDependencies.swift` (remove `var libraryViewModel` accessor line ~802)
- Modify: `rishi/rishi/AppDependencies.swift` `BootstrappedServices` (remove `let libraryViewModel: LibraryViewModel` and its construction in `buildServices`)

- [ ] **Step 0: Ordering** — run **Task 7 (SignedInView) before this task** so the host exists. If executing strictly in number order, instead create a minimal `SignedInView` shell here first.

- [ ] **Step 1: Construct the VM in `SignedInView`**

```swift
// inside SignedInView.init(services:user:...)
_libraryVM = State(initialValue: LibraryViewModel(
    bookStore: services.bookStore,
    positionStore: services.positionStore,
    storage: services.bookFileStorage,
    currentUserId: { [userId = user.id] in userId }
))
```
> NOTE: confirm `User`'s id property name (`user.id` vs `user.userId`) and the `UserID` type while implementing.

- [ ] **Step 2: Pass `libraryVM` into the library tab** where RootView previously read `deps.services?.libraryViewModel`.

- [ ] **Step 3: Remove from registry** — delete the `libraryViewModel` forwarder (line ~802), the `BootstrappedServices.libraryViewModel` stored property, and its construction in `buildServices`.

- [ ] **Step 4: Package gate** — `swift test --package-path apps/apple/Packages/RishiLibrary`. Expected: PASS.

- [ ] **Step 5: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add rishi/rishi/Views/SignedInView.swift rishi/rishi/AppDependencies.swift
git commit -m "refactor(apple): SignedInView owns LibraryViewModel; remove from registry"
```

---

## STEP 2 — Extract `ReadAloudController` (TDD)

> This concern HAS testable logic, so it is test-first. The controller owns the `ReaderTTSBridge` and the read-aloud paragraph/passage state currently held as RootView `@State` (`readerTTSBridge`, `readAloudParagraphs`, `currentReadAloudParagraph`, `showTTSControls`, `showTTSPicker`, `ttsPickerInitial`) and the methods `startPDFReadAloud`/`startEPUBReadAloud`/`startReadAloud`/`updateReadAloudParagraph`/`stopReadAloud` (RootView lines ~980–1085).

### Task 5: `ReadAloudController` with unit tests

**Files:**
- Create: `rishi/rishi/Audio/ReadAloudController.swift`
- Create: `rishi/rishiTests/ReadAloudControllerTests.swift`
- Modify: `rishi/rishi/RootView.swift` (remove the TTS `@State` + methods; delegate to controller)
- Modify: `rishi/rishi/AppDependencies.swift` (remove `makeReaderTTSBridge(...)` lines ~1040–1056; expose the raw TTS services it used: `ttsEngine`, `ttsState`, `ttsPrewarmer`, `ttsSettingsStore`)

- [ ] **Step 1: Write the failing test** (`ReadAloudControllerTests.swift`)

```swift
import Testing
import RishiCore
import RishiTesting
@testable import rishi

@MainActor
@Suite("ReadAloudController")
struct ReadAloudControllerTests {
    @Test("start sets paragraphs and active state; stop clears them")
    func startThenStop() async {
        let controller = ReadAloudController(services: .testDouble(), userId: .testUser)
        await controller.start(paragraphs: ["one", "two"])
        #expect(controller.isActive == true)
        #expect(controller.paragraphs == ["one", "two"])
        await controller.stop()
        #expect(controller.isActive == false)
        #expect(controller.currentParagraph == nil)
    }

    @Test("passage change updates currentParagraph by index")
    func passageChangeUpdatesText() async {
        let controller = ReadAloudController(services: .testDouble(), userId: .testUser)
        await controller.start(paragraphs: ["alpha", "beta", "gamma"])
        controller.handlePassageChange(1)
        #expect(controller.currentParagraph == "beta")
    }
}
```
> NOTE: `BootstrappedServices.testDouble()` and `UserID.testUser` — reuse existing `RishiTesting` fixtures; if a services double does not exist, add a minimal factory in `RishiTesting` that fills the TTS fields with existing test doubles (do NOT mock the engine — use the existing TTS test double the package already ships). Confirm names before writing.

- [ ] **Step 2: Run to verify it fails** — MAIN orchestrator: `xcodebuild ... test -only-testing:rishiTests/ReadAloudControllerTests`. Expected: FAIL ("cannot find 'ReadAloudController'").

- [ ] **Step 3: Implement `ReadAloudController`** — move the bridge creation (former `makeReaderTTSBridge` body) and RootView read-aloud methods into the controller:

```swift
import SwiftUI
import RishiAudio
import RishiCore

@MainActor
@Observable
final class ReadAloudController {
    private let services: BootstrappedServices
    private let userId: UserID
    private var bridge: ReaderTTSBridge?

    private(set) var paragraphs: [String] = []
    private(set) var currentParagraph: String? = nil
    var isActive: Bool { bridge != nil }

    // UI toggles formerly on RootView:
    var showControls = false
    var showPicker = false
    var pickerInitial: TTSSettings = .default

    init(services: BootstrappedServices, userId: UserID) {
        self.services = services
        self.userId = userId
    }

    func start(paragraphs: [String],
               onParagraphsExhausted: @escaping () async -> [String] = { [] }) async {
        self.paragraphs = paragraphs
        let tracker = TTSPassageTracker()
        let bridge = ReaderTTSBridge(
            engine: services.ttsEngine,
            state: services.ttsState,
            tracker: tracker,
            prewarmer: services.ttsPrewarmer,
            settingsStore: services.ttsSettingsStore,
            userId: userId,
            onPassageChange: { [weak self] idx in self?.handlePassageChange(idx) },
            onParagraphsExhausted: onParagraphsExhausted
        )
        self.bridge = bridge
        // move the existing startReadAloud body here (bridge.start(...))
    }

    func handlePassageChange(_ index: Int?) {
        guard let index, paragraphs.indices.contains(index) else { currentParagraph = nil; return }
        currentParagraph = paragraphs[index]
    }

    func stop() async {
        // move the existing stopReadAloud body here
        bridge = nil
        currentParagraph = nil
        paragraphs = []
        showControls = false
    }
}
```
> Move the PDF/EPUB-specific paragraph extraction (`startPDFReadAloud`, `startEPUBReadAloud`) in as `func startPDF(vm:)`/`func startEPUB(vm:)` that compute paragraphs then call `start(...)`. Preserve the existing follow-on chapter handler exactly (it backs the Bug-4 cross-chapter fix — see recent commits).

- [ ] **Step 4: Run to verify it passes** — MAIN orchestrator: `xcodebuild ... test -only-testing:rishiTests/ReadAloudControllerTests`. Expected: PASS.

- [ ] **Step 5: Rewire RootView** — replace TTS `@State` with `@State private var readAloud: ReadAloudController?` created in the signed-in branch; route the controls overlay (`readAloudControlsOverlay`, lines ~937–978) and reader destinations to call `readAloud?.startPDF/startEPUB/stop`. Delete the moved methods and state from RootView. Delete `makeReaderTTSBridge` from `AppDependencies`.

- [ ] **Step 6: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS (incl. existing ReaderTTS/Bug-4 tests).

- [ ] **Step 7: Commit**

```bash
git add rishi/rishi/Audio/ReadAloudController.swift rishi/rishiTests/ReadAloudControllerTests.swift rishi/rishi/RootView.swift rishi/rishi/AppDependencies.swift
git commit -m "refactor(apple): extract ReadAloudController from RootView"
```

---

## STEP 3 — Extract `AppRouter` (TDD)

> Owns navigation + deep-link + scene state. Moves RootView's `libraryPath`, scene-storage cells, `restoreSceneState`/`persistSceneState`/`showLibraryRoot`/`showConversations` (lines ~490–553), and `handleOpenURL` deep-link dispatch (the `.onOpenURL` body). Routes through existing `DeepLinkRouter` and `RishiSceneState`/`ReaderRoute`/`NavigationPath` storage helpers — do NOT reimplement their logic.

### Task 6: `AppRouter` with unit tests

**Files:**
- Create: `rishi/rishi/App/AppRouter.swift`
- Create: `rishi/rishiTests/AppRouterTests.swift`
- Modify: `rishi/rishi/RootView.swift` (remove nav/scene/deep-link members; bind to router)
- Modify: `rishi/rishi/rishiApp.swift` (own + inject `AppRouter`)

- [ ] **Step 1: Write the failing tests** (`AppRouterTests.swift`)

```swift
import Testing
import SwiftUI
import RishiCore
@testable import rishi

@MainActor
@Suite("AppRouter")
struct AppRouterTests {
    @Test("routing a book deep link pushes a reader route")
    func deepLinkPushesReader() {
        let router = AppRouter()
        let id = UUID()
        router.handle(url: URL(string: "rishi://book/\(id.uuidString)")!)
        #expect(router.path.count == 1)
    }

    @Test("unknown deep link does not mutate the path")
    func unknownDeepLinkNoop() {
        let router = AppRouter()
        router.handle(url: URL(string: "rishi://nonsense")!)
        #expect(router.path.isEmpty)
    }

    @Test("showLibraryRoot clears the navigation path")
    func showLibraryRootClears() {
        let router = AppRouter()
        router.handle(url: URL(string: "rishi://book/\(UUID().uuidString)")!)
        router.showLibraryRoot()
        #expect(router.path.isEmpty)
    }

    @Test("persist then restore round-trips selected tab + open book")
    func sceneRoundTrip() {
        let router = AppRouter()
        let book = UUID()
        router.applyRestored(tabRaw: RishiSceneState(selectedTab: .library, openBookId: BookID(book)).encodeForStorage(),
                             openBookIdRaw: "")
        #expect(router.selectedTab == .library)
    }
}
```
> NOTE: confirm `BookID`/`ReaderRoute` construction labels and `DeepLinkDestination` cases while implementing; the deep-link assertion may need to map a `.book(id)` destination → `path.append(ReaderRoute...)`. Adjust the assertions to the real destination→route mapping found in RootView's current `.onOpenURL` body.

- [ ] **Step 2: Run to verify it fails** — MAIN orchestrator: `xcodebuild ... test -only-testing:rishiTests/AppRouterTests`. Expected: FAIL ("cannot find 'AppRouter'").

- [ ] **Step 3: Implement `AppRouter`**

```swift
import SwiftUI
import RishiCore

@MainActor
@Observable
final class AppRouter {
    var path = NavigationPath()
    var selectedTab: MacTab = .library
    private let deepLinks = DeepLinkRouter()

    func handle(url: URL) {
        switch deepLinks.route(url) {
        // move RootView's existing .onOpenURL destination handling here verbatim,
        // mutating `path` / `selectedTab` instead of RootView @State.
        default:
            break
        }
    }

    func showLibraryRoot() { path = NavigationPath() }

    func showConversations() {
        // move RootView.showConversations body (push conversations route)
    }

    func applyRestored(tabRaw: String, openBookIdRaw: String) {
        let decoded = RishiSceneState.decodeSceneRestoreCells(tabRaw: tabRaw, openBookIdRaw: openBookIdRaw)
        selectedTab = decoded.state.selectedTab
        if let restoredPath = decoded.path { path = restoredPath }
        // preserve legacyId fallback handling exactly as RootView.restoreSceneState did
    }

    func persistCells() -> (tabRaw: String, openBookIdRaw: String) {
        // move RootView.persistSceneState encoding here
    }
}
```
> Move the bodies of `restoreSceneState`, `persistSceneState`, `showConversations`, and the `.onOpenURL` handler from RootView into the matching methods, swapping `self.libraryPath`/scene `@State` for `path`/`selectedTab`. Keep the legacy-bare-UUID fallback intact (covered by `RootViewSceneRestorationTests`).

- [ ] **Step 4: Run to verify it passes** — MAIN orchestrator: `xcodebuild ... test -only-testing:rishiTests/AppRouterTests`. Expected: PASS.

- [ ] **Step 5: Own + inject the router** in `rishiApp.swift`:

```swift
@State private var router = AppRouter()
// in WindowGroup content:
RootView()
    .environment(router)
    .environment(\.rishiAuthService, deps.services?.authService)
    .environment(\.appDependencies, deps)
    .environment(\.macCommandRouter, deps.macCommandRouter)
    .task { await deps.bootstrap() }
```

- [ ] **Step 6: Rewire RootView** — read `@Environment(AppRouter.self) private var router`; bind the library `NavigationStack` to `router.path`; replace `.onOpenURL { handleOpenURL($0) }` with `router.handle(url:)`; wire `@SceneStorage` cells to `router.applyRestored`/`router.persistCells` in the existing `.task`/`.onChange`. Delete the moved RootView members.

- [ ] **Step 7: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS (incl. `RootViewSceneRestorationTests`).

- [ ] **Step 8: Commit**

```bash
git add rishi/rishi/App/AppRouter.swift rishi/rishiTests/AppRouterTests.swift rishi/rishi/RootView.swift rishi/rishi/rishiApp.swift
git commit -m "refactor(apple): extract AppRouter for navigation/deep-link/scene state"
```

---

## STEP 4 — Extract host views; reduce RootView to an auth switch

### Task 7: `SignedInView` shell

**Files:**
- Create: `rishi/rishi/Views/SignedInView.swift`
- Modify: `rishi/rishi/RootView.swift` (move `realBodyContent` signed-in branch into `SignedInView`)

> Run this BEFORE Task 4 (Task 4 places `LibraryViewModel` ownership here).

- [ ] **Step 1: Create `SignedInView`** owning the authenticated composition (library tab + hosts + read-aloud overlay), receiving `services: BootstrappedServices` and `user: User`:

```swift
import SwiftUI
import RishiLibrary
import RishiCore

struct SignedInView: View {
    let services: BootstrappedServices
    let user: User
    @Environment(AppRouter.self) private var router
    @State private var libraryVM: LibraryViewModel   // populated in Task 4
    @State private var readAloud: ReadAloudController?
    @State private var selectedConversation: Conversation? = nil
    @State private var paywallFeature: PaywallFeature? = nil
    @State private var showSettings = false

    init(services: BootstrappedServices, user: User) {
        self.services = services
        self.user = user
        _libraryVM = State(initialValue: LibraryViewModel(
            bookStore: services.bookStore,
            positionStore: services.positionStore,
            storage: services.bookFileStorage,
            currentUserId: { [id = user.id] in id }
        ))
    }

    var body: some View {
        // move RootView.libraryTab + sheets (.sheet/.fullScreenCover) here,
        // using libraryVM, ChatPanelHostView/ConversationChatHost, PaywallHost, OnboardingHost.
    }
}
```

- [ ] **Step 2: Move sheets + library tab** body from RootView into `SignedInView.body`, swapping factory calls for the Step-1 hosts.

- [ ] **Step 3: Typecheck** — `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Views/SignedInView.swift`.

- [ ] **Step 4: Commit**

```bash
git add rishi/rishi/Views/SignedInView.swift rishi/rishi/RootView.swift
git commit -m "refactor(apple): extract SignedInView from RootView"
```

### Task 8: `OnboardingHost` + reduce RootView to the auth switch

**Files:**
- Create: `rishi/rishi/Onboarding/OnboardingHost.swift`
- Modify: `rishi/rishi/RootView.swift` (final shrink)

- [ ] **Step 1: Create `OnboardingHost`** wrapping the onboarding flow, built from `services.onboardingState` / `services.onboardingCoordinator` (match real onboarding view init while implementing).

- [ ] **Step 2: Reduce `RootView.body`** to:

```swift
var body: some View {
    if !authProbeComplete {
        ProgressView()            // loading branch (keep existing probe gating)
    } else if let user = currentUser, let services = deps?.services {
        SignedInView(services: services, user: user)
    } else {
        SignedOutView()           // existing signed-out surface
    }
}
```
> Keep the existing auth-probe `.task` and `consumePendingMacIntent` wiring (Mac command dispatch) — route Mac intents through `router`/`SignedInView` callbacks as appropriate; preserve current behavior.

- [ ] **Step 3: Typecheck** — `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Onboarding/OnboardingHost.swift`.

- [ ] **Step 4: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS. Confirm `RootView.swift` is now under ~200 lines.

- [ ] **Step 5: Commit**

```bash
git add rishi/rishi/Onboarding/OnboardingHost.swift rishi/rishi/RootView.swift
git commit -m "refactor(apple): RootView reduced to auth switch + composition"
```

---

## STEP 5 — Slim & split `AppDependencies` into a service-only registry

### Task 9: Split `AppDependencies` by feature

**Files:**
- Modify: `rishi/rishi/AppDependencies.swift` (keep core type + two-phase bootstrap + `BootstrappedServices` + env keys)
- Create: `AppDependencies+Auth.swift`, `+Persistence.swift`, `+Sync.swift`, `+Chat.swift`, `+Audio.swift`, `+Billing.swift`, `+Library.swift` under `rishi/rishi/`

> Pure mechanical move: each feature's forwarder accessors and any helper construction move into an `extension AppDependencies { ... }` in its own file. No behavior change. By now all VM factories are already gone (Steps 1–2).

- [ ] **Step 1: Move forwarder accessors** for each feature group into its extension file. Keep `init()`, `bootstrap()`, `buildServices()`, `services`, `cachedUserId`, env keys, and `BootstrappedServices` in `AppDependencies.swift`.

- [ ] **Step 2: Typecheck each new file** — `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/AppDependencies+Auth.swift` (repeat per file).

- [ ] **Step 3: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS (incl. `AppDependenciesBootstrapTests`). Confirm `AppDependencies.swift` is materially smaller and no file exceeds ~300 lines.

- [ ] **Step 4: Commit**

```bash
git add rishi/rishi/AppDependencies*.swift
git commit -m "refactor(apple): split AppDependencies into per-feature service registry"
```

---

## Final verification (MAIN orchestrator)

- [ ] Full build + test: `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' test` — all suites PASS.
- [ ] Manual smoke (simulator): launch → library loads → open a book (PDF + EPUB) → start read-aloud → cross a page/chapter boundary (Bug-4) → open chat → open paywall → background/foreground (scene restore) → deep link `rishi://book/<id>`.
- [ ] Confirm: `RootView.swift` ≤ ~200 lines; no VM factories remain in `AppDependencies`; every VM is `@State`-owned by a host view; no host view receives `AppDependencies` (only `BootstrappedServices`/specific services).

---

## Self-Review notes

- **Spec coverage:** service-only registry (Task 1–5, 9), view-owned VMs (Tasks 1–4, 7), AppRouter for nav/deep-link/scene (Task 6), ReadAloudController for TTS (Task 5), auth-switch RootView (Task 8), file split (Task 9) — all present.
- **Ordering caveat:** Task 7 (`SignedInView`) must precede Task 4 (`LibraryViewModel` ownership) — flagged in Task 4 Step 0. Executor should run 1, 2, 3, 7, 4, 5, 6, 8, 9 if it prefers, OR create the minimal SignedInView shell inside Task 4.
- **Known unknowns to confirm at implementation time (each flagged inline as NOTE):** exact `PaywallView` / `ConversationsListView` / `ChatPanelView` initializer labels; `User` id property; `BookID`/`ReaderRoute`/`DeepLinkDestination` construction; existence of a `BootstrappedServices` test double in `RishiTesting`. These are signature confirmations, not design gaps.
- **TDD honesty:** logic-bearing extractions (`AppRouter`, `ReadAloudController`) are test-first with real failing tests run via xcodebuild by the orchestrator. Pure presentation moves are guarded by per-file typecheck + the full existing suite — appropriate since SwiftUI view composition has no unit-testable behavior of its own.
