# SignedInView Decomposition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose the 678-line `SignedInView.swift` into small single-responsibility views (one struct per file, every `@ViewBuilder` promoted to a `View`), a thin `SignedInViewModel` for shell modal state, and named wiring modifiers — behavior-preserving.

**Architecture:** Incremental strangler. Introduce the shell viewModel first, then pull each `@ViewBuilder` method out into its own `View` in the matching app-target feature folder (`Reader/`, `Library/`, `Billing/`, `Mac/`, `DeepLink/`). Reader destinations own their VM/controller/sync via `@State`, which lets us delete the `ReaderViewModelCache` workaround.

**Tech Stack:** Swift 6 (strict concurrency, default-isolation = MainActor), SwiftUI Observation, Swift Testing, `rishi.xcodeproj` app target.

---

## Conventions & Build/Test Rules (read first)

- Swift Testing only. No emojis. No engine changes. Do not flip default-isolation.
- App-target sources (`apps/apple/rishi/rishi/`) are not in a SwiftPM package; their tests live in `apps/apple/rishi/rishiTests/` and only run under `xcodebuild`.
- **Subagents MUST NOT run `xcodebuild`** (watchdog stall). A subagent sanity-checks with `xcrun --sdk iphonesimulator swiftc -typecheck <file>` (unresolved cross-module symbols are expected/OK) and may run `swift test --package-path ...` for touched packages.
- **The MAIN orchestrator runs the real gate:** `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' test`. Run after Tasks 2, 4, 5 (and at minimum the end).
- Commit scope: only under `apps/apple/{Packages,rishi,scripts,fastlane,docs}`. Stay on `main`.
- The current `SignedInView.swift` (678 lines) is the source of truth for every move; copy logic verbatim and adjust only the parameter surface described here. Behavior must be identical.

## File Structure

**New files:**
- `rishi/rishi/Reader/NavigationLazyBook.swift`
- `rishi/rishi/Reader/EpubPlaceholderView.swift`
- `rishi/rishi/Reader/GlassCardBackground.swift`
- `rishi/rishi/Billing/PaywallFeature.swift`
- `rishi/rishi/Shell/SignedInViewModel.swift`
- `rishi/rishiTests/SignedInViewModelTests.swift`
- `rishi/rishi/Library/LibraryTabView.swift`
- `rishi/rishi/Reader/ReaderDestinationView.swift`
- `rishi/rishi/Reader/PDFReaderDestination.swift`
- `rishi/rishi/Reader/EPUBReaderDestination.swift`
- `rishi/rishi/Reader/ReadAloudControlsOverlay.swift`
- `rishi/rishi/Mac/MacCommandDispatchModifier.swift`
- `rishi/rishi/DeepLink/DeepLinkHandlingModifier.swift`
- `rishi/rishi/Mac/SceneRestorationModifier.swift`

**Modified:** `rishi/rishi/Views/SignedInView.swift` (shrinks to a composition root), and `rishi/rishi/AppDependencies+Settings.swift` is untouched.

> Ordering note: the spec's step order is refined here to reduce churn — the shell viewModel (Task 2) lands before the view extractions so children consume it from the start. Final order: 1 (helpers) → 2 (viewModel) → 3 (LibraryTabView) → 4 (Reader) → 5 (wiring).

---

### Task 1: One struct per file — move the helpers out of `SignedInView.swift`

**Files:**
- Create: `rishi/rishi/Reader/NavigationLazyBook.swift`, `rishi/rishi/Reader/EpubPlaceholderView.swift`, `rishi/rishi/Reader/GlassCardBackground.swift`, `rishi/rishi/Billing/PaywallFeature.swift`
- Modify: `rishi/rishi/Views/SignedInView.swift` (remove the moved struct definitions; keep `ReaderViewModelCache` for now — it is deleted in Task 4)

- [ ] **Step 1: Create the four files** by moving each struct VERBATIM from `SignedInView.swift` (lines 34-56 `GlassCardBackground` + `PaywallFeature`, 99-142 `NavigationLazyBook`, 147-170 `EpubPlaceholderView`) into its own file. Each file gets the imports it needs:
  - `NavigationLazyBook.swift`: `import SwiftUI`, `import RishiCore` (Book/BookID), `import RishiDB`? — match what `BookStore`/`Book`/`BookID` need; copy the import set from SignedInView and prune to what the struct uses (`SwiftUI`, `RishiCore`).
  - `EpubPlaceholderView.swift`: `import SwiftUI`, `import RishiCore`.
  - `GlassCardBackground.swift`: `import SwiftUI`.
  - `PaywallFeature.swift`: `import Foundation`.
  Keep each type `internal` (no access keyword) and keep the doc comments.

- [ ] **Step 2: Remove the four moved structs** from `SignedInView.swift`. Leave `ReaderViewModelCache` (lines 74-97) in place.

- [ ] **Step 3: Typecheck** the new files: `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Reader/NavigationLazyBook.swift` (repeat per file; clean parse, cross-module errors OK).

- [ ] **Step 4: Commit**

```bash
git add rishi/rishi/Reader/NavigationLazyBook.swift rishi/rishi/Reader/EpubPlaceholderView.swift rishi/rishi/Reader/GlassCardBackground.swift rishi/rishi/Billing/PaywallFeature.swift rishi/rishi/Views/SignedInView.swift
git commit -m "refactor(apple): one struct per file - move SignedInView helpers out"
```

---

### Task 2: Introduce `SignedInViewModel` (TDD) and move shell modal state into it

**Files:**
- Create: `rishi/rishi/Shell/SignedInViewModel.swift`
- Create: `rishi/rishiTests/SignedInViewModelTests.swift`
- Modify: `rishi/rishi/Views/SignedInView.swift`

- [ ] **Step 1: Write the failing test** (`SignedInViewModelTests.swift`)

```swift
import Testing
import RishiCore
@testable import rishi

@MainActor
@Suite("SignedInViewModel")
struct SignedInViewModelTests {
    @Test("requestPaywall sets the paywall feature by name")
    func requestPaywall() {
        let model = SignedInViewModel()
        model.requestPaywall("Read Aloud")
        #expect(model.paywallFeature?.name == "Read Aloud")
    }

    @Test("dismissPaywall clears the feature")
    func dismissPaywall() {
        let model = SignedInViewModel()
        model.requestPaywall("Voice Chat")
        model.dismissPaywall()
        #expect(model.paywallFeature == nil)
    }

    @Test("present(conversation:) sets the selected conversation")
    func presentConversation() {
        let model = SignedInViewModel()
        let convo = Conversation.fixture()   // use the RishiTesting/RishiChat fixture; confirm the real factory
        model.present(conversation: convo)
        #expect(model.selectedConversation == convo)
    }

    @Test("hint(_:) caches a book by id; hint(for:) reads it back")
    func bookHints() {
        let model = SignedInViewModel()
        let book = Book.fixture()            // confirm the real fixture/init
        model.hint(book)
        #expect(model.hint(for: book.id)?.id == book.id)
    }

    @Test("showSettings flag toggles")
    func settings() {
        let model = SignedInViewModel()
        #expect(model.showSettings == false)
        model.requestSettings()
        #expect(model.showSettings == true)
    }
}
```
> NOTE: confirm the real `Conversation` / `Book` fixtures (look in `Packages/RishiTesting/` and existing `RishiChat`/`RishiCore` tests). If `Conversation`/`Book` aren't `Equatable`, assert on `.id` instead of the whole value.

- [ ] **Step 2: Run to verify it fails** — MAIN orchestrator: `xcodebuild ... test -only-testing:rishiTests/SignedInViewModelTests`. Expected: FAIL ("cannot find 'SignedInViewModel'").

- [ ] **Step 3: Implement `SignedInViewModel.swift`**

```swift
import SwiftUI
import RishiCore
import RishiChat

/// Presentation state for the signed-in shell. Owns the cross-cutting modal
/// triggers that children raise (paywall, conversation sheet, settings) plus
/// the transient book-hint cache used to paint reader first-frames without a
/// DB round-trip. View-free so it is unit-testable.
@MainActor
@Observable
final class SignedInViewModel {
    var selectedConversation: Conversation?
    var paywallFeature: PaywallFeature?
    var showSettings = false
    private(set) var bookHints: [BookID: Book] = [:]

    func requestPaywall(_ name: String) { paywallFeature = PaywallFeature(name: name) }
    func dismissPaywall() { paywallFeature = nil }

    func present(conversation: Conversation) { selectedConversation = conversation }

    func requestSettings() { showSettings = true }

    func hint(_ book: Book) { bookHints[book.id] = book }
    func hint(for id: BookID) -> Book? { bookHints[id] }
}
```

- [ ] **Step 4: Run to verify it passes** — MAIN orchestrator: `xcodebuild ... test -only-testing:rishiTests/SignedInViewModelTests`. Expected: PASS.

- [ ] **Step 5: Rewire `SignedInView` to own the model and drop the loose @State.** In `SignedInView`:
  - Replace `@State private var selectedConversation`, `@State private var paywallFeature`, `@State private var showSettings`, `@State private var bookHints` with a single `@State private var model = SignedInViewModel()`.
  - Update every reference: `selectedConversation` → `model.selectedConversation`; `paywallFeature = PaywallFeature(name: X)` → `model.requestPaywall(X)`; `paywallFeature = nil` → `model.dismissPaywall()`; `showSettings = true` → `model.requestSettings()`; `bookHints[id] = book` → `model.hint(book)`; `bookHints[id]` reads → `model.hint(for: id)`.
  - For the sheet bindings, use `@Bindable var model = model` (or `Bindable(model)`) so `.sheet(item: $model.selectedConversation)`, `.sheet(item: $model.paywallFeature)`, `.sheet(isPresented: $model.showSettings)` work with the `@Observable` model. Confirm the Swift 6 Observation binding pattern.
  - Keep the `@ViewBuilder` methods for now (they are extracted in Tasks 3-4); they just read/write `model` instead of local state.

- [ ] **Step 6: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add rishi/rishi/Shell/SignedInViewModel.swift rishi/rishiTests/SignedInViewModelTests.swift rishi/rishi/Views/SignedInView.swift
git commit -m "refactor(apple): add SignedInViewModel; move shell modal state off SignedInView"
```

---

### Task 3: Extract `LibraryTabView`

**Files:**
- Create: `rishi/rishi/Library/LibraryTabView.swift`
- Modify: `rishi/rishi/Views/SignedInView.swift`

- [ ] **Step 1: Create `LibraryTabView`** by moving the `libraryTab(...)` body (current SignedInView lines 398-443) into a `struct LibraryTabView: View`. It OWNS `libraryVM` (move the `@State private var libraryVM` + its `init` construction from SignedInView into this view). It needs:

```swift
struct LibraryTabView: View {
    let services: BootstrappedServices
    let user: User
    @Environment(AppRouter.self) private var router
    @State private var libraryVM: LibraryViewModel

    let model: SignedInViewModel          // for hints / settings / conversation triggers
    let onCacheUserId: (UserID) -> Void
    let onShowChats: () -> Void

    init(services: BootstrappedServices, user: User, model: SignedInViewModel,
         onCacheUserId: @escaping (UserID) -> Void, onShowChats: @escaping () -> Void) {
        self.services = services; self.user = user; self.model = model
        self.onCacheUserId = onCacheUserId; self.onShowChats = onShowChats
        let userId = user.id
        _libraryVM = State(initialValue: LibraryViewModel(
            bookStore: services.bookStore, positionStore: services.positionStore,
            storage: services.bookFileStorage, currentUserId: { userId }))
    }

    var body: some View {
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
                path: bindableRouter.path,
                importCoordinator: services.importCoordinator,
                onOpenBook: { book in
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                },
                onShowSettings: { model.requestSettings() },
                onShowChats: onShowChats,
                onImported: { outcomes in
                    let successes = outcomes.compactMap(\.book)
                    guard successes.count == 1, let book = successes.first else { return }
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                }
            )
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderDestinationView(route: route, services: services, userId: user.id,
                                      hint: model.hint(for: route.bookId),
                                      onRequestPaywall: { model.requestPaywall($0) })
            }
            .navigationDestination(for: ConversationsRoute.self) { _ in
                ConversationsListHost(services: services, userId: user.id,
                                      onSelect: { model.present(conversation: $0) })
            }
            .task(id: user.id) {
                onCacheUserId(user.id)
                async let sample = services.sampleBookInstaller.installIfNeeded(ownerId: user.id)
                async let reader = services.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
                _ = await (sample, reader)
                await libraryVM.refresh()
            }
        }
        .environment(libraryVM)
        .sheet(isPresented: Bindable(model).showSettings) {
            SettingsSheet(services: services, user: user, onSignedOut: onSignedOut)
        }
    }
}
```
> IMPORTANT NOTES while implementing:
> - `ReaderDestinationView` is created in Task 4. For THIS task, temporarily keep calling SignedInView's existing `destinationView`/reader methods via a closure passed in, OR sequence Task 4 before wiring the `ReaderRoute` destination. Simplest: in Task 3, keep the `ReaderRoute` destination pointing at the OLD reader `@ViewBuilder` methods (which still live in SignedInView) by passing a `readerDestination: (ReaderRoute) -> AnyView` closure into `LibraryTabView`; Task 4 replaces it with `ReaderDestinationView`. Pick whichever keeps the build green and report it.
> - `ReaderRoute` needs a `bookId` accessor for `model.hint(for: route.bookId)`. If `ReaderRoute` has no single `bookId` property (it is an enum with associated `BookID` per case), add a small computed `var bookId: BookID` extension in `Reader/ReaderDestinationView.swift` (Task 4) or compute the hint inside the destination switch instead. For Task 3, compute hints the same way the old `destinationView` did (`model.hint(for:)` per case).
> - `onSignedOut` must be threaded into `LibraryTabView` (the settings sheet needs it). Add it to the init.
> - `.environment(libraryVM)` must wrap the content that contains `LibraryRootView` and the reader destinations (they read `@Environment(LibraryViewModel.self)`). Keep it where SignedInView had it.

- [ ] **Step 2: Update `SignedInView`** to compose `LibraryTabView(services:user:model:onCacheUserId:onShowChats:onSignedOut:)` in its body instead of calling `libraryTab(...)`. Remove the `libraryTab` method, the `@State libraryVM` + its init construction, and the `conversationsDestination` method (now inlined in LibraryTabView) from SignedInView. SignedInView keeps the reader `@ViewBuilder` methods until Task 4 (passed via the closure if you chose that path).

- [ ] **Step 3: Typecheck** `xcrun --sdk iphonesimulator swiftc -typecheck rishi/rishi/Library/LibraryTabView.swift`.

- [ ] **Step 4: Commit**

```bash
git add rishi/rishi/Library/LibraryTabView.swift rishi/rishi/Views/SignedInView.swift
git commit -m "refactor(apple): extract LibraryTabView; it owns LibraryViewModel"
```

---

### Task 4: Extract the Reader destinations; delete `ReaderViewModelCache`

**Files:**
- Create: `rishi/rishi/Reader/ReaderDestinationView.swift`, `rishi/rishi/Reader/PDFReaderDestination.swift`, `rishi/rishi/Reader/EPUBReaderDestination.swift`, `rishi/rishi/Reader/ReadAloudControlsOverlay.swift`
- Modify: `rishi/rishi/Views/SignedInView.swift` (remove reader methods + reader `@State` + `ReaderViewModelCache`), `rishi/rishi/Library/LibraryTabView.swift` (point destination at `ReaderDestinationView`)

- [ ] **Step 1: `ReadAloudControlsOverlay.swift`** — promote `readAloudControlsOverlay(services:)` (lines 630-667) to a `View`:

```swift
struct ReadAloudControlsOverlay: View {
    let controller: ReadAloudController
    let ttsState: TTSPlaybackState
    var body: some View {
        if controller.showControls, let bridge = controller.bridge {
            ReadAloudControlsView(
                state: ttsState,
                onPlayPause: { Task { ttsState.status == .playing ? await bridge.pause() : await bridge.resume() } },
                onStop: { Task { await controller.stop() } },
                onOpenPicker: { controller.showPicker = true },
                onPreviousParagraph: { Task { await bridge.previous() } },
                onNextParagraph: { Task { await bridge.next() } },
                onRepeatParagraph: { Task { await bridge.repeatCurrent() } }
            )
            .modifier(GlassCardBackground(cornerRadius: RishiRadius.large))
            .shadow(radius: RishiSpacing.s)
            .padding(.horizontal, RishiSpacing.m)
            .padding(.bottom, RishiSpacing.s)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: controller.showControls)
        }
    }
}
```
> Imports: `SwiftUI`, `RishiAudio` (TTSPlaybackState, ReadAloudControlsView), `RishiUIKit` (RishiRadius/RishiSpacing).

- [ ] **Step 2: `PDFReaderDestination.swift`** — promote `pdfReaderDestination` (lines 479-548). It OWNS its VM + read-aloud controller + sync binding via `@State`:

```swift
struct PDFReaderDestination: View {
    let book: Book
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: PDFReaderViewModel
    @State private var readAloud: ReadAloudController?
    @State private var syncBinding: PDFReaderPositionSyncBinding?

    init(book: Book, services: BootstrappedServices, userId: UserID, onRequestPaywall: @escaping (String) -> Void) {
        self.book = book; self.services = services; self.userId = userId; self.onRequestPaywall = onRequestPaywall
        _vm = State(initialValue: PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: Self.fileURL(for: book),
            positionStore: services.positionStore))
    }

    var body: some View {
        PDFReaderScreen(
            viewModel: vm,
            readerSettingsStore: services.readerSettingsStore,
            highlightStore: services.highlightStore,
            onReadAloud: FeatureFlags.readAloud ? { startReadAloud() } : nil,
            chatPresenter: services.chatPresenter,
            readAloudParagraph: readAloud?.currentParagraph
        )
        .task { syncBinding = PDFReaderPositionSyncBinding(viewModel: vm, syncEngine: services.syncEngine) }
        .onDisappear { syncBinding = nil; Task { await readAloud?.stop() } }
        .overlay(alignment: .bottom) {
            if let readAloud { ReadAloudControlsOverlay(controller: readAloud, ttsState: services.ttsState) }
        }
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } })) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(initial: ra.pickerInitial, userId: userId, store: services.ttsSettingsStore,
                    onDismiss: { settings in ra.pickerInitial = settings; ra.showPicker = false })
                    .presentationDetents([.medium])
            }
        }
    }

    private func startReadAloud() {
        Task {
            let level = await services.entitlementService.snapshot()
            guard level == .pro else { onRequestPaywall("Read Aloud"); return }
            if readAloud == nil {
                readAloud = ReadAloudController(ttsEngine: services.ttsEngine, ttsState: services.ttsState,
                    ttsSettingsStore: services.ttsSettingsStore, ttsPrewarmer: services.ttsPrewarmer, userId: userId)
            }
            await readAloud?.startPDF(vm: vm)
        }
    }

    static func fileURL(for book: Book) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(book.fileURL)
    }
}
```
> The `readerVMCache.drop(book.id)` from the old `.onDisappear` is no longer needed — the `@State` VM dies with the destination view. Confirm there is no OTHER side effect of `drop` you need to preserve (there is not; it only removed the cache entry).

- [ ] **Step 3: `EPUBReaderDestination.swift`** — promote `epubReaderDestination` (lines 550-626) the same way. It additionally sets `epubVM.onUserNavigation = { _ in Task { await readAloud?.stop() } }` inside `.task`, and its DEBUG `UITestBypass` entitlement branch must be preserved verbatim:

```swift
struct EPUBReaderDestination: View {
    let book: Book
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: EPUBReaderViewModel
    @State private var readAloud: ReadAloudController?
    @State private var syncBinding: EPUBReaderPositionSyncBinding?

    init(book: Book, services: BootstrappedServices, userId: UserID, onRequestPaywall: @escaping (String) -> Void) {
        self.book = book; self.services = services; self.userId = userId; self.onRequestPaywall = onRequestPaywall
        _vm = State(initialValue: EPUBReaderViewModel(
            book: book, userId: userId,
            documentURL: PDFReaderDestination.fileURL(for: book),
            positionStore: services.positionStore))
    }

    var body: some View {
        EPUBReaderScreen(
            viewModel: vm,
            readerSettingsStore: services.readerSettingsStore,
            highlightStore: services.highlightStore,
            onReadAloud: FeatureFlags.readAloud ? { startReadAloud() } : nil,
            chatPresenter: services.chatPresenter,
            readAloudParagraph: readAloud?.currentParagraph
        )
        .task {
            vm.onUserNavigation = { _ in Task { await readAloud?.stop() } }
            syncBinding = EPUBReaderPositionSyncBinding(viewModel: vm, syncEngine: services.syncEngine)
        }
        .onDisappear { syncBinding = nil; Task { await readAloud?.stop() } }
        .overlay(alignment: .bottom) {
            if let readAloud { ReadAloudControlsOverlay(controller: readAloud, ttsState: services.ttsState) }
        }
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } })) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(initial: ra.pickerInitial, userId: userId, store: services.ttsSettingsStore,
                    onDismiss: { settings in ra.pickerInitial = settings; ra.showPicker = false })
                    .presentationDetents([.medium])
            }
        }
    }

    private func startReadAloud() {
        Task {
            let level = await services.entitlementService.snapshot()
            var entitled = level == .pro
            #if DEBUG
            if UITestBypass.isActive { entitled = true }
            #endif
            guard entitled else { onRequestPaywall("Read Aloud"); return }
            if readAloud == nil {
                readAloud = ReadAloudController(ttsEngine: services.ttsEngine, ttsState: services.ttsState,
                    ttsSettingsStore: services.ttsSettingsStore, ttsPrewarmer: services.ttsPrewarmer, userId: userId)
            }
            await readAloud?.startEPUB(vm: vm)
        }
    }
}
```

- [ ] **Step 4: `ReaderDestinationView.swift`** — promote `destinationView(for:)` (lines 457-477) to a `View` that switches on the route, wrapping each in `NavigationLazyBook`:

```swift
struct ReaderDestinationView: View {
    let route: ReaderRoute
    let services: BootstrappedServices
    let userId: UserID
    let hint: Book?
    let onRequestPaywall: (String) -> Void
    @Environment(AppRouter.self) private var router

    var body: some View {
        switch route {
        case .pdf(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                PDFReaderDestination(book: book, services: services, userId: userId, onRequestPaywall: onRequestPaywall)
            }
        case .epub(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                EPUBReaderDestination(book: book, services: services, userId: userId, onRequestPaywall: onRequestPaywall)
            }
        case .unsupportedFormat(let bookId):
            NavigationLazyBook(bookId: bookId, hint: hint, bookStore: services.bookStore) { book in
                EpubPlaceholderView(book: book) { if !router.path.isEmpty { router.path.removeLast() } }
            }
        }
    }
}
```
> `hint` is resolved by the caller (LibraryTabView) via `model.hint(for: route.bookId)`. Add a `var bookId: BookID` computed extension on `ReaderRoute` in this file if the enum lacks one (each case carries a `BookID`):
> ```swift
> extension ReaderRoute { var bookId: BookID { switch self { case .pdf(let id), .epub(let id), .unsupportedFormat(let id): return id } } }
> ```
> Confirm the real case names/associated types before writing this.

- [ ] **Step 5: Wire LibraryTabView's `ReaderRoute` destination to `ReaderDestinationView`** (replacing the Task-3 placeholder/closure):
```swift
.navigationDestination(for: ReaderRoute.self) { route in
    ReaderDestinationView(route: route, services: services, userId: user.id,
                          hint: model.hint(for: route.bookId),
                          onRequestPaywall: { model.requestPaywall($0) })
}
```

- [ ] **Step 6: Delete from `SignedInView`:** the reader `@ViewBuilder` methods (`destinationView`, `pdfReaderDestination`, `epubReaderDestination`, `readAloudControlsOverlay`), the reader `@State` (`readAloud`, `pdfSyncBinding`, `epubSyncBinding`, `readerVMCache`), the `pdfFileURL` helper, and the `ReaderViewModelCache` class. Grep the app target to confirm `ReaderViewModelCache` has no remaining references.

- [ ] **Step 7: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS (incl. reader/TTS suites). This is the behavior-sensitive step.

- [ ] **Step 8: Commit**

```bash
git add rishi/rishi/Reader/ReaderDestinationView.swift rishi/rishi/Reader/PDFReaderDestination.swift rishi/rishi/Reader/EPUBReaderDestination.swift rishi/rishi/Reader/ReadAloudControlsOverlay.swift rishi/rishi/Library/LibraryTabView.swift rishi/rishi/Views/SignedInView.swift
git commit -m "refactor(apple): extract reader destinations; destinations own VM; drop ReaderViewModelCache"
```

---

### Task 5: Extract the wiring into named view modifiers

**Files:**
- Create: `rishi/rishi/Mac/MacCommandDispatchModifier.swift`, `rishi/rishi/DeepLink/DeepLinkHandlingModifier.swift`, `rishi/rishi/Mac/SceneRestorationModifier.swift`
- Modify: `rishi/rishi/Views/SignedInView.swift`

- [ ] **Step 1: `MacCommandDispatchModifier.swift`** — move `consumePendingMacIntent()` + `mapReaderTheme` (lines 343-394) into a `ViewModifier` that reads `@Environment(\.macCommandRouter)` and `@Environment(AppRouter.self)`, takes `readerDefaults` + an `onShowChats`/`onShowLibraryRoot` it can call via the router, and attaches the `.task(id: commandRouter?.pendingIntent)`. Expose `extension View { func macCommandDispatch(readerDefaults:) -> some View }`. Move the `consumePendingMacIntent` switch VERBATIM (it calls `router.showLibraryRoot()`, `router.showConversations()`, posts `NotificationCenter` events, sets `services.readerDefaults.theme`). The modifier needs `readerDefaults` (pass it) and `router` (env).

- [ ] **Step 2: `DeepLinkHandlingModifier.swift`** — move the `.onOpenURL` block (lines 297-315) into a `ViewModifier` exposing `extension View { func deepLinkHandling(router:services:model:libraryVM:) -> some View }`. It sets `router.onBookResolved = { model.hint($0) }`, `router.onConversationResolved = { model.present(conversation: $0) }`, `router.onFileURL = { url in Task { _ = await services.importCoordinator.importBooks([url]); await libraryVM.refresh() } }`, then `router.handle(url:bookStore:conversationStore:)`. Keep the callback wiring identical.
> NOTE: `libraryVM` now lives in `LibraryTabView`, not `SignedInView`. So the deep-link file-import refresh must reach the library VM. Options: (a) apply this modifier inside `LibraryTabView` (which has `libraryVM`) rather than `SignedInView`; (b) route the refresh through `router`/a callback. Prefer (a): attach `.deepLinkHandling(...)` in `LibraryTabView` where both `libraryVM` and `model` are in scope. Confirm the `.onOpenURL` still fires at the same scope (a NavigationStack ancestor) so behavior is unchanged; report the placement.

- [ ] **Step 3: `SceneRestorationModifier.swift`** — move the scene-restore `.task` (lines 321-332, with the `sceneRestored` one-shot guard as private `@State` in the modifier) and the persist `.onChange(of: router.path)` (lines 334-338) into a `ViewModifier` exposing `extension View { func sceneRestoration(router:services:tabRaw:openBookIdRaw:model:) -> some View }`. The restore task sets `router.onBookResolved = { model.hint($0) }` then `await router.applyRestored(tabRaw:openBookIdRaw:bookStore:)`; the persist writes `tabRaw`/`openBookIdRaw` bindings from `router.persistCells()`. Keep `tabRaw`/`openBookIdRaw` as `@Binding`.

- [ ] **Step 4: Apply the modifiers** — replace the inline blocks in `SignedInView` (and `LibraryTabView` for deep-link per Step 2 note) with `.macCommandDispatch(...)`, `.deepLinkHandling(...)`, `.sceneRestoration(...)`. Remove the now-empty `consumePendingMacIntent`/`mapReaderTheme` methods from SignedInView. Preserve modifier ORDER relative to the sheets.

- [ ] **Step 5: Typecheck** each new modifier file with `swiftc -typecheck`.

- [ ] **Step 6: MAIN orchestrator gate** — full `xcodebuild ... test`. Expected: PASS. Report final `SignedInView.swift` line count (target ~120-150) and confirm it has no `@ViewBuilder` helper methods.

- [ ] **Step 7: Commit**

```bash
git add rishi/rishi/Mac/MacCommandDispatchModifier.swift rishi/rishi/DeepLink/DeepLinkHandlingModifier.swift rishi/rishi/Mac/SceneRestorationModifier.swift rishi/rishi/Views/SignedInView.swift rishi/rishi/Library/LibraryTabView.swift
git commit -m "refactor(apple): extract Mac-command, deep-link, scene-restore into view modifiers"
```

---

## Final verification (MAIN orchestrator)

- [ ] Full `xcodebuild ... test` — all suites PASS.
- [ ] Manual smoke (simulator): launch → open PDF + EPUB → Read Aloud across a page/chapter boundary (the eliminated-cache risk) → voice picker → chat sheet → paywall gate (tap a Pro feature) → settings sheet → deep link `rishi://book/<id>` → background/foreground (scene restore).
- [ ] Confirm: `SignedInView.swift` ≤ ~150 lines, no `@ViewBuilder` helper methods; `ReaderViewModelCache` deleted; each reader destination owns its VM; `SignedInViewModel` holds the modal state and has unit tests.

## Self-Review notes

- **Spec coverage:** one-struct-per-file (Task 1), @ViewBuilder→View for all six (Tasks 3-4 + inlined conversations), reader destinations own VM + cache deleted (Task 4), SignedInViewModel + tests (Task 2), wiring modifiers (Task 5), lean SignedInView (Task 5). All covered.
- **Ordering caveat:** Task 3 wires the `ReaderRoute` destination before `ReaderDestinationView` exists (Task 4). Resolved via the Task-3 placeholder-closure note; executor must keep the build green between 3 and 4 (the orchestrator only gates at 2/4/5, so Task 3's intermediate state need not compile in isolation as long as Task 4 lands before the next gate — but prefer keeping it green).
- **Known unknowns flagged inline (NOTE):** real `Conversation`/`Book` fixtures + `Equatable`; `ReaderRoute.bookId` accessor/case names; Observation `@Bindable` binding pattern; exact `ReadAloudControlsView`/`VoiceAndSpeedPicker`/reader-screen init labels (copy verbatim from current `SignedInView`). These are confirmations, not design gaps.
- **Behavior-sensitive:** Task 4 (cache deletion) is the one place a regression could hide; gated by the full suite + manual smoke.
