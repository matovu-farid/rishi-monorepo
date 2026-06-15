# VM Init-Injection + RishiLibrary Colocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make host views receive their `@Observable` view models via init-injection (construction moved to thin per-feature factories), convert `LibraryRootView` off `@Environment`, and colocate `LibraryViewModel` with its views — all behavior-preserving.

**Architecture:** Each feature gets an app-target factory (`extension VM { static func make(services:...) }`) — the factory lives in the app target because it references `BootstrappedServices` (packages cannot). Host views take `let vm` and seed `@State` from it for lifetime stability. RishiLibrary's `LibraryViewModel.swift` moves next to its views.

**Tech Stack:** Swift 6 (strict concurrency, default-isolation = MainActor), SwiftUI Observation, Swift Testing, SwiftPM + `rishi.xcodeproj`.

---

## Conventions & Build/Test Rules (read first)

- Swift Testing only. No emojis. No engine changes. Do not flip default-isolation.
- **Subagents MUST NOT run `xcodebuild`.** Sanity-check with `xcrun --sdk iphonesimulator swiftc -typecheck <file>` (cross-module errors expected/OK) and `swift test --package-path ...` for touched packages.
- **The MAIN orchestrator runs the gate** with EXPLICIT MODULES (this is what catches transitive-import regressions):
  `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' build SWIFT_ENABLE_EXPLICIT_MODULES=YES` after each task, and `... test` (explicit modules) at the end. A task is done only when the build prints `** BUILD SUCCEEDED **` with no `error:` lines.
- Commit scope: only under `apps/apple/{Packages,rishi,scripts,fastlane,docs}`. Stay on `main`.
- **Factories must live in the app target** (`rishi/rishi/`), not the packages — they reference `BootstrappedServices`.
- Verified VM initializers (copy labels exactly):
  - `PaywallViewModel.init(productService: StoreKitProductService, purchaseService: any PurchaseProtocol, restoreService: any RestoreProtocol, managePresenter: ManageSubscriptionPresenter)`
  - `ConversationsListViewModel.init(conversationStore: any ConversationStore, messageStore: any MessageStore)`
  - `ChatPanelViewModel.init(conversation: Conversation, bookId: BookID?, chatService: any ChatService, messageStore: any MessageStore, streamingState: ChatStreamingState = .init())`
  - `PDFReaderViewModel.init(book: Book, userId: UserID, documentURL: URL, positionStore: any PositionStore)`
  - `EPUBReaderViewModel.init(book: Book, userId: UserID, documentURL: URL, positionStore: any PositionStore)`
  - `LibraryViewModel.init(bookStore: any BookStore, positionStore: any PositionStore, storage: BookFileStorage, currentUserId: @escaping @MainActor () -> UserID?)`
- The documents-dir file URL helper currently lives at `PDFReaderDestination.fileURL(for:)`.

## File Structure

**New (app-target factories, colocated):**
- `rishi/rishi/Billing/PaywallViewModel+Make.swift`
- `rishi/rishi/Chat/ChatViewModels+Make.swift` (ConversationsListViewModel + ChatPanelViewModel makers)
- `rishi/rishi/Reader/ReaderViewModels+Make.swift` (PDF + EPUB makers; includes the documents-dir URL helper)
- `rishi/rishi/Library/LibraryViewModel+Make.swift`

**Modified:** `PaywallHost.swift`, `ChatHost.swift`, `PDFReaderDestination.swift`, `EPUBReaderDestination.swift`, `ReaderDestinationView.swift`, `Views/SignedInView.swift`, `Library/LibraryTabView.swift`, `Packages/RishiLibrary/.../LibraryRootView.swift`.

**Moved:** `Packages/RishiLibrary/Sources/RishiLibrary/ViewModel/LibraryViewModel.swift` → `.../Views/LibraryViewModel.swift`.

---

### Task 1: Add the per-feature VM factories (no call-site changes)

**Files:** create the four `+Make.swift` files above.

- [ ] **Step 1: `Billing/PaywallViewModel+Make.swift`**
```swift
import RishiBilling

extension PaywallViewModel {
    @MainActor
    static func make(services: BootstrappedServices) -> PaywallViewModel {
        PaywallViewModel(
            productService: services.storeKitProductService,
            purchaseService: services.purchaseService,
            restoreService: services.restoreService,
            managePresenter: services.manageSubscriptionPresenter
        )
    }
}
```

- [ ] **Step 2: `Chat/ChatViewModels+Make.swift`**
```swift
import RishiChat
import RishiCore

extension ConversationsListViewModel {
    @MainActor
    static func make(services: BootstrappedServices) -> ConversationsListViewModel {
        ConversationsListViewModel(conversationStore: services.conversationStore, messageStore: services.messageStore)
    }
}

extension ChatPanelViewModel {
    @MainActor
    static func make(conversation: Conversation, services: BootstrappedServices) -> ChatPanelViewModel {
        ChatPanelViewModel(conversation: conversation, bookId: conversation.bookId,
                           chatService: services.chatService, messageStore: services.messageStore)
    }
}
```

- [ ] **Step 3: `Reader/ReaderViewModels+Make.swift`**
```swift
import Foundation
import RishiCore
import RishiReader

enum ReaderDocumentURL {
    static func url(for book: Book) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(book.fileURL)
    }
}

extension PDFReaderViewModel {
    @MainActor
    static func make(book: Book, userId: UserID, services: BootstrappedServices) -> PDFReaderViewModel {
        PDFReaderViewModel(book: book, userId: userId, documentURL: ReaderDocumentURL.url(for: book),
                           positionStore: services.positionStore)
    }
}

extension EPUBReaderViewModel {
    @MainActor
    static func make(book: Book, userId: UserID, services: BootstrappedServices) -> EPUBReaderViewModel {
        EPUBReaderViewModel(book: book, userId: userId, documentURL: ReaderDocumentURL.url(for: book),
                            positionStore: services.positionStore)
    }
}
```

- [ ] **Step 4: `Library/LibraryViewModel+Make.swift`**
```swift
import RishiCore
import RishiLibrary

extension LibraryViewModel {
    @MainActor
    static func make(services: BootstrappedServices, user: User) -> LibraryViewModel {
        let userId = user.id
        return LibraryViewModel(bookStore: services.bookStore, positionStore: services.positionStore,
                                storage: services.bookFileStorage, currentUserId: { userId })
    }
}
```

- [ ] **Step 5: Typecheck each file** (`xcrun --sdk iphonesimulator swiftc -typecheck <file>`), then commit.
```bash
git add rishi/rishi/Billing/PaywallViewModel+Make.swift rishi/rishi/Chat/ChatViewModels+Make.swift rishi/rishi/Reader/ReaderViewModels+Make.swift rishi/rishi/Library/LibraryViewModel+Make.swift
git commit -m "refactor(apple): add per-feature view-model factories"
```

- [ ] **Step 6: MAIN orchestrator gate** — explicit-modules build. Expected `** BUILD SUCCEEDED **`.

---

### Task 2: Init-inject the Billing + Chat hosts

**Files:** `rishi/rishi/Billing/PaywallHost.swift`, `rishi/rishi/Chat/ChatHost.swift`, `rishi/rishi/Views/SignedInView.swift`

- [ ] **Step 1: `PaywallHost`** — take `let vm`, seed `@State`, drop service-construction:
```swift
struct PaywallHost: View {
    let feature: PaywallFeature
    let onDismiss: () -> Void
    @State private var vm: PaywallViewModel
    init(feature: PaywallFeature, vm: PaywallViewModel, onDismiss: @escaping () -> Void) {
        self.feature = feature; self.onDismiss = onDismiss
        _vm = State(initialValue: vm)
    }
    var body: some View { PaywallView(viewModel: vm, feature: feature.name, onDismiss: onDismiss) }
}
```
> Confirm the real `PaywallView` init labels from the current PaywallHost body; keep them identical.

- [ ] **Step 2: `ConversationsListHost`** — take `let vm`:
```swift
struct ConversationsListHost: View {
    let userId: UserID
    let onSelect: (Conversation) -> Void
    @State private var vm: ConversationsListViewModel
    init(vm: ConversationsListViewModel, userId: UserID, onSelect: @escaping (Conversation) -> Void) {
        self.userId = userId; self.onSelect = onSelect
        _vm = State(initialValue: vm)
    }
    var body: some View { /* unchanged body, using vm */ }
}
```
> Keep the existing body (the `ConversationsListView(...)` call, `.navigationTitle`, the `chatRefreshAdapter.setActive/clearActive` `.task`/`.onDisappear`). `chatRefreshAdapter` was taken from `services` before — if the host still needs `services` for the adapter, KEEP a `let services` param too; only the VM construction moves out. Read the current file and preserve every behavior.

- [ ] **Step 3: `ConversationChatHost`** — take `let vm`:
```swift
struct ConversationChatHost: View {
    @State private var vm: ChatPanelViewModel
    let onFreeUserTap: () -> Void
    let services: BootstrappedServices   // keep if the body's ChatPanelHost wiring needs it
    init(vm: ChatPanelViewModel, services: BootstrappedServices, onFreeUserTap: @escaping () -> Void) {
        _vm = State(initialValue: vm); self.services = services; self.onFreeUserTap = onFreeUserTap
    }
    var body: some View { /* unchanged: NavigationStack { ChatPanelHost(...) } with voice/onFreeUserTap wiring */ }
}
```

- [ ] **Step 4: `ChatPanelHostView` (async)** — keep building in `.task`, but via the factory: replace the inline `ChatPanelViewModel(conversation:...)` with `ChatPanelViewModel.make(conversation: convo, services: services)`. No signature change otherwise.

- [ ] **Step 5: Update call sites in `SignedInView`** (and `LibraryTabView` for ConversationsListHost):
  - paywall sheet: `PaywallHost(feature: feature, vm: PaywallViewModel.make(services: services), onDismiss: { model.dismissPaywall() })`
  - selectedConversation sheet: `ConversationChatHost(vm: ChatPanelViewModel.make(conversation: convo, services: services), services: services, onFreeUserTap: { model.requestPaywall("Voice Chat") })`
  - conversations destination (in `LibraryTabView`): `ConversationsListHost(vm: ConversationsListViewModel.make(services: services), userId: user.id, onSelect: { model.present(conversation: $0) })` (pass `services` too if the host kept it for the refresh adapter).

- [ ] **Step 6: Typecheck** changed files; commit.
```bash
git add rishi/rishi/Billing/PaywallHost.swift rishi/rishi/Chat/ChatHost.swift rishi/rishi/Views/SignedInView.swift rishi/rishi/Library/LibraryTabView.swift
git commit -m "refactor(apple): init-inject Billing + Chat host view models"
```

- [ ] **Step 7: MAIN orchestrator gate** — explicit-modules build. Expected `** BUILD SUCCEEDED **`.

---

### Task 3: Init-inject the reader destinations

**Files:** `rishi/rishi/Reader/PDFReaderDestination.swift`, `rishi/rishi/Reader/EPUBReaderDestination.swift`, `rishi/rishi/Reader/ReaderDestinationView.swift`

- [ ] **Step 1: `PDFReaderDestination`** — take `let vm` (drop `book`-based construction; keep `services`/`userId`/`onRequestPaywall` and the `@State` readAloud + sync binding):
```swift
struct PDFReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void
    @State private var vm: PDFReaderViewModel
    @State private var readAloud: ReadAloudController?
    @State private var syncBinding: PDFReaderPositionSyncBinding?
    init(vm: PDFReaderViewModel, services: BootstrappedServices, userId: UserID, onRequestPaywall: @escaping (String) -> Void) {
        _vm = State(initialValue: vm); self.services = services; self.userId = userId; self.onRequestPaywall = onRequestPaywall
    }
    // body unchanged (uses vm); remove the static fileURL(for:) helper — it now lives in ReaderDocumentURL.
}
```
> Remove `PDFReaderDestination.fileURL(for:)` (moved to `ReaderDocumentURL` in Task 1). Grep for other references to `PDFReaderDestination.fileURL` and update them to `ReaderDocumentURL.url(for:)`.

- [ ] **Step 2: `EPUBReaderDestination`** — same: take `let vm`, drop book-based construction, keep the `vm.onUserNavigation` wiring + UITestBypass entitlement branch + read-aloud/sync `@State`.

- [ ] **Step 3: `ReaderDestinationView`** — build the VM via the factory inside each `NavigationLazyBook` content closure (it has the resolved `book`) and pass it in:
```swift
case .pdf(let bookId):
    NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
        PDFReaderDestination(vm: PDFReaderViewModel.make(book: book, userId: userId, services: services),
                             services: services, userId: userId, onRequestPaywall: onRequestPaywall)
    }
case .epub(let bookId):
    NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
        EPUBReaderDestination(vm: EPUBReaderViewModel.make(book: book, userId: userId, services: services),
                              services: services, userId: userId, onRequestPaywall: onRequestPaywall)
    }
// unsupportedFormat case unchanged
```

- [ ] **Step 4: Typecheck** changed files; commit.
```bash
git add rishi/rishi/Reader/PDFReaderDestination.swift rishi/rishi/Reader/EPUBReaderDestination.swift rishi/rishi/Reader/ReaderDestinationView.swift
git commit -m "refactor(apple): init-inject reader destination view models"
```

- [ ] **Step 5: MAIN orchestrator gate** — explicit-modules build. Expected `** BUILD SUCCEEDED **`. (Behavior-sensitive: this touches the reader/TTS path — at the end, verify reader/TTS tests in the full `test` run.)

---

### Task 4: Convert `LibraryRootView` to init-injection

**Files:** `Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryRootView.swift`, `rishi/rishi/Library/LibraryTabView.swift`

- [ ] **Step 1: `LibraryRootView`** — replace `@Environment(LibraryViewModel.self) private var viewModel` with a stored `let viewModel: LibraryViewModel`, and add `viewModel: LibraryViewModel` as the FIRST parameter to BOTH public inits (the `importCoordinator:` one and the `path:importCoordinator:` one), assigning `self.viewModel = viewModel`. The body's `@Bindable var vm = viewModel` stays (it now binds the injected property). Remove the `@Environment` import usage if unused.

- [ ] **Step 2: `LibraryTabView`** — build the VM via the factory and pass it; drop the environment injection:
  - change `@State private var libraryVM: LibraryViewModel` construction in `init` to `_libraryVM = State(initialValue: LibraryViewModel.make(services: services, user: user))`.
  - in `body`, change `LibraryRootView(path:importCoordinator:onOpenBook:...)` to `LibraryRootView(viewModel: libraryVM, path: bindableRouter.path, importCoordinator: services.importCoordinator, onOpenBook:..., onShowSettings:..., onShowChats:..., onImported:...)`.
  - REMOVE the `.environment(libraryVM)` modifier (LibraryRootView no longer reads it; confirmed it was the only reader).
  - `libraryVM.refresh()` in the `.task(id:)` and the deep-link `onFileURL` still use `libraryVM` directly — unchanged.

- [ ] **Step 3: Package test** — `swift test --package-path apps/apple/Packages/RishiLibrary`. Expected: PASS.

- [ ] **Step 4: Commit.**
```bash
git add apps/apple/Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryRootView.swift rishi/rishi/Library/LibraryTabView.swift
git commit -m "refactor(apple): LibraryRootView takes injected view model (drop @Environment)"
```

- [ ] **Step 5: MAIN orchestrator gate** — explicit-modules build. Expected `** BUILD SUCCEEDED **`.

---

### Task 5: Flatten RishiLibrary (colocate the view model)

**Files:** move `Packages/RishiLibrary/Sources/RishiLibrary/ViewModel/LibraryViewModel.swift` → `Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryViewModel.swift`

- [ ] **Step 1: Move the file** with `git mv`:
```bash
git mv apps/apple/Packages/RishiLibrary/Sources/RishiLibrary/ViewModel/LibraryViewModel.swift apps/apple/Packages/RishiLibrary/Sources/RishiLibrary/Views/LibraryViewModel.swift
```
Then remove the now-empty `ViewModel/` directory if git leaves it (`rmdir` if present). The file content is unchanged.

- [ ] **Step 2: Package test** — `swift test --package-path apps/apple/Packages/RishiLibrary`. Expected: PASS (SwiftPM globs by directory; module unchanged).

- [ ] **Step 3: Commit.**
```bash
git add -A apps/apple/Packages/RishiLibrary/Sources/RishiLibrary
git commit -m "refactor(apple): colocate LibraryViewModel beside its views"
```

- [ ] **Step 4: MAIN orchestrator final gate** — explicit-modules `build` AND `test`. Expected `** BUILD SUCCEEDED **` and all tests pass.

---

## Final verification (MAIN orchestrator)

- [ ] Explicit-modules `xcodebuild ... test` — `** BUILD SUCCEEDED **`, all suites pass, zero `error:`.
- [ ] Manual smoke: open PDF + EPUB → Read Aloud across a boundary → voice picker → chat → paywall gate → settings → library loads/refreshes.
- [ ] Confirm: no host view constructs its VM from `services` in its own `init` except via a `.make(...)` factory call at the call site; `LibraryRootView` takes an injected `viewModel`; `LibraryViewModel.swift` sits in `Views/`.

## Self-Review notes

- **Spec coverage:** factories (Task 1), Billing/Chat init-injection (Task 2), reader init-injection + fileURL relocation (Task 3), LibraryRootView env→init (Task 4), RishiLibrary colocation (Task 5), ChatPanelHostView async exception (Task 2 Step 4). All covered.
- **Placeholder scan:** the "body unchanged" notes reference the current file's exact body, which the implementer must copy verbatim — flagged with explicit "read the current file / preserve every behavior" instructions, not vague TODOs.
- **Type consistency:** factory names `make(...)`, `ReaderDocumentURL.url(for:)` used consistently across tasks. Host inits all `init(vm:...)` seeding `@State`.
- **Known unknowns (confirm at implementation):** exact `PaywallView`/`ConversationsListView`/`ChatPanelHost` init labels and whether ConversationsListHost/ConversationChatHost still need `services` for adapter/voice wiring — copy from current files. `Conversation.bookId` exists (used by the old factory).
- **Behavior-sensitive:** Task 3 (reader). Gated by explicit-modules build + final reader/TTS test run + smoke.
