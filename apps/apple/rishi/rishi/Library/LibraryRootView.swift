import Foundation
import TipKit


import SwiftUI

struct FirstPromptImportLifecycleEvent {
    enum Kind: Equatable {
        case cancelled
        case began(supportedCount: Int)
        case registered(BookID)
        case finished([BookID])
        case retired
        case accepted(BookID)
        case rejected
    }

    let attemptID: UUID
    let identity: LibraryAccountIdentity
    let kind: Kind
}

struct FirstPromptImportReducer {
    enum Event {
        case cancelled
        case began(supportedCount: Int)
        case registered(BookID)
        case finished(candidateBookIDs: [BookID])
        case acceptanceFinished(BookID, accepted: Bool)
        case retired
    }

    enum Action: Equatable {
        case accept(BookID)
        case publishAccepted(BookID)
        case finishAccepted(BookID)
        case finishRejected
        case wait
        case ignore
    }

    private(set) var began = false
    private(set) var terminal = false
    private(set) var selectedCandidate: BookID?
    private(set) var accepted = false
    private(set) var retired = false
    private var acceptanceStarted = false
    private var acceptanceFinished = false
    private var acceptancePublished = false
    private var completed = false

    mutating func reduce(_ event: Event) -> Action {
        guard !completed else { return .ignore }
        switch event {
        case .cancelled, .retired:
            terminal = true
            if case .retired = event { retired = true }
            completed = true
            return .finishRejected
        case .began:
            guard !began, !terminal else { return .ignore }
            began = true
            return .wait
        case let .registered(bookID):
            guard began, !terminal else { return .ignore }
            guard selectedCandidate == nil else { return .ignore }
            selectedCandidate = bookID
            acceptanceStarted = true
            return .accept(bookID)
        case let .finished(candidateBookIDs):
            guard began, !terminal else { return .ignore }
            terminal = true
            if let selectedCandidate {
                guard acceptanceFinished else { return .wait }
                completed = true
                return accepted ? .finishAccepted(selectedCandidate) : .finishRejected
            }
            guard let first = candidateBookIDs.first else {
                completed = true
                return .finishRejected
            }
            selectedCandidate = first
            acceptanceStarted = true
            return .accept(first)
        case let .acceptanceFinished(bookID, succeeded):
            guard acceptanceStarted, selectedCandidate == bookID else { return .ignore }
            accepted = succeeded
            acceptanceFinished = true
            guard terminal else {
                guard succeeded, !acceptancePublished else { return .wait }
                acceptancePublished = true
                return .publishAccepted(bookID)
            }
            completed = true
            return succeeded ? .finishAccepted(bookID) : .finishRejected
        }
    }
}

@MainActor
final class FirstPromptImportAdapter {
    let attemptID: UUID
    let identity: LibraryAccountIdentity
    private let isCurrent: @MainActor () -> Bool
    private let onLifecycle: @MainActor (FirstPromptImportLifecycleEvent) -> Void
    private let acceptCandidate: @MainActor (Book) async -> Bool
    private let onAccepted: @MainActor (BookID) -> Void
    private let onTerminated: @MainActor (Bool) -> Void
    private var reducer = FirstPromptImportReducer()
    private var candidates: [BookID: Book] = [:]
    private var acceptanceTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var didTerminate = false
    private var didPublishAcceptance = false

    var wasRetired: Bool { reducer.retired }

    init(
        attemptID: UUID,
        identity: LibraryAccountIdentity,
        isCurrent: @escaping @MainActor () -> Bool,
        onLifecycle: @escaping @MainActor (FirstPromptImportLifecycleEvent) -> Void,
        acceptCandidate: @escaping @MainActor (Book) async -> Bool,
        onAccepted: @escaping @MainActor (BookID) -> Void,
        onTerminated: @escaping @MainActor (Bool) -> Void
    ) {
        self.attemptID = attemptID
        self.identity = identity
        self.isCurrent = isCurrent
        self.onLifecycle = onLifecycle
        self.acceptCandidate = acceptCandidate
        self.onAccepted = onAccepted
        self.onTerminated = onTerminated
    }

    func cancelled() {
        emit(.cancelled)
        apply(.cancelled)
    }

    func began(supportedCount: Int) {
        emit(.began(supportedCount: supportedCount))
        apply(.began(supportedCount: supportedCount))
    }

    func registered(_ outcome: ImportCoordinator.ImportOutcome) {
        guard let book = outcome.book, isSupported(book) else { return }
        candidates[book.id] = book
        emit(.registered(book.id))
        apply(.registered(book.id))
    }

    func finished(_ outcomes: [ImportCoordinator.ImportOutcome]) {
        let books = outcomes.compactMap(\.book).filter(isSupported)
        for book in books { candidates[book.id] = book }
        let ids = books.map(\.id)
        emit(.finished(ids))
        apply(.finished(candidateBookIDs: ids))
    }

    func cancelIfStillPicking() {
        guard !reducer.began, !didTerminate else { return }
        cancelled()
    }

    func retainImportTask(_ task: Task<Void, Never>) {
        guard isCurrent(), !didTerminate else {
            task.cancel()
            return
        }
        importTask = task
    }

    func retire() {
        guard !didTerminate else { return }
        acceptanceTask?.cancel()
        importTask?.cancel()
        emit(.retired)
        apply(.retired)
    }

    private func isSupported(_ book: Book) -> Bool {
        book.formatType == .epub || book.formatType == .pdf
    }

    private func emit(_ kind: FirstPromptImportLifecycleEvent.Kind) {
        guard isCurrent() else { return }
        onLifecycle(.init(attemptID: attemptID, identity: identity, kind: kind))
    }

    private func apply(_ event: FirstPromptImportReducer.Event) {
        guard isCurrent(), !didTerminate else { return }
        let action = reducer.reduce(event)
        switch action {
        case let .accept(bookID):
            guard let book = candidates[bookID] else {
                apply(.acceptanceFinished(bookID, accepted: false))
                return
            }
            acceptanceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.acceptCandidate(book)
                guard self.isCurrent(), !Task.isCancelled else { return }
                self.emit(result ? .accepted(bookID) : .rejected)
                self.apply(.acceptanceFinished(bookID, accepted: result))
            }
        case let .publishAccepted(bookID):
            guard !didPublishAcceptance else { return }
            didPublishAcceptance = true
            onAccepted(bookID)
        case let .finishAccepted(bookID):
            didTerminate = true
            if !didPublishAcceptance {
                didPublishAcceptance = true
                onAccepted(bookID)
            }
            importTask = nil
            acceptanceTask = nil
            candidates.removeAll()
            onTerminated(true)
        case .finishRejected:
            didTerminate = true
            importTask = nil
            acceptanceTask = nil
            candidates.removeAll()
            onTerminated(false)
        case .wait, .ignore:
            break
        }
    }
}

private enum LibraryMacCommandNotification {
    static let importBook = Notification.Name("RishiCommand.importBook")
    static let focusSearch = Notification.Name("RishiCommand.focusSearch")
}

@MainActor
public struct LibraryRootView: View {
    @Environment(LibraryViewModel.self) private var vm: LibraryViewModel
    @Environment(AppRouter.self) private var router
    @Environment(TrialIntroPresentationState.self) private var trialPresentationState


    public let importCoordinator: ImportCoordinator
    public let onOpenBook: (Book) -> Void

    public let onShowSettings: (() -> Void)
    public let onShowChats: (() -> Void)?
    
    private var importTip = ImportBooksTip()

    public let onImported:
        (@MainActor ([ImportCoordinator.ImportOutcome]) -> Bool)?
    let firstPromptImportAdapter: FirstPromptImportAdapter?

    public let sharePackageService: SharePackageService?
    let sharedReadingAPI: SharedReadingAPI?
    let sharedReadingRepair: (@Sendable (BookID) async -> Bool)?
    private let closeReaderBeforeBookDeletion: (@MainActor (Book) async -> Void)?
    private let accountIdentity: LibraryAccountIdentity?
    @State private var trialRegistration: TrialIntroPresentationState.Registration?
    @State private var activeImportOperationIDs: Set<UUID> = []
    @State private var activeDeletionOperationIDs: Set<UUID> = []

    ///

    private let externalPath: Binding<NavigationPath>?

    @State private var internalDocumentPickerPresented = false
    @State private var selectionMode = false
    @State private var selectedBookIDs: Set<BookID> = []
    @State private var showShareComposer = false
    @State private var shareKind: ShareKind = .selection
    @State private var shareBookIDs: [BookID] = []
    @State private var showSharedReadingComposer = false
    @State private var sharedReadingBook: Book?
    @State private var pendingSharedReadingBook: Book?
    @State private var showSharedReadingSwitchConfirmation = false
    @State private var pendingCreatorInvitation: SharedReadingInvitation?
    private let externalDocumentPickerPresented: Binding<Bool>?

    private var documentPickerPresented: Binding<Bool> {
        externalDocumentPickerPresented ?? $internalDocumentPickerPresented
    }

    private func refreshLibraryAndPrewarm(_ vm: LibraryViewModel) async {
        await vm.refresh()
        guard let sharePackageService else { return }
        await sharePackageService.prewarm(bookIDs: vm.books.map(\.id))
    }

    private func handleImportBookCommand() {
        #if canImport(UIKit)
        documentPickerPresented.wrappedValue = true
        #endif
    }

    @MainActor
    private func handleImportedAndMarkReaderOpen(_ outcomes: [ImportCoordinator.ImportOutcome]) {
        guard onImported?(outcomes) == true else { return }
        let successes = outcomes.compactMap(\.book)
        let openedBook = successes.count == 1
            ? successes.first
            : successes.first(where: { $0.formatType == .epub || $0.formatType == .pdf })
        if let openedBook {
            vm.markImportReaderOpenRequested(bookID: openedBook.id)
        }
    }

    init(
      
        importCoordinator: ImportCoordinator,
        onOpenBook: @escaping (Book) -> Void,
        onShowSettings: @escaping (() -> Void),
        onImported: (@MainActor ([ImportCoordinator.ImportOutcome]) -> Bool)? =
            nil,
        firstPromptImportAdapter: FirstPromptImportAdapter? = nil,
        documentPickerPresented: Binding<Bool>? = nil,
        sharePackageService: SharePackageService? = nil,
        sharedReadingAPI: SharedReadingAPI? = nil,
        sharedReadingRepair: (@Sendable (BookID) async -> Bool)? = nil,
        closeReaderBeforeBookDeletion: (@MainActor (Book) async -> Void)? = nil,
        accountIdentity: LibraryAccountIdentity? = nil,
        onShowChats: (() -> Void)? = nil
    ) {
 
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.onShowChats = onShowChats
        self.onImported = onImported
        self.firstPromptImportAdapter = firstPromptImportAdapter
        self.sharePackageService = sharePackageService
        self.sharedReadingAPI = sharedReadingAPI
        self.sharedReadingRepair = sharedReadingRepair
        self.closeReaderBeforeBookDeletion = closeReaderBeforeBookDeletion
        self.accountIdentity = accountIdentity
        self.externalPath = nil
        self.externalDocumentPickerPresented = documentPickerPresented
    }

    init(
     
        path: Binding<NavigationPath>,
        importCoordinator: ImportCoordinator,
        onOpenBook: @escaping (Book) -> Void,
        onShowSettings: @escaping (() -> Void),
        onImported: (@MainActor ([ImportCoordinator.ImportOutcome]) -> Bool)? =
            nil,
        firstPromptImportAdapter: FirstPromptImportAdapter? = nil,
        documentPickerPresented: Binding<Bool>? = nil,
        sharePackageService: SharePackageService? = nil,
        sharedReadingAPI: SharedReadingAPI? = nil,
        sharedReadingRepair: (@Sendable (BookID) async -> Bool)? = nil,
        closeReaderBeforeBookDeletion: (@MainActor (Book) async -> Void)? = nil,
        accountIdentity: LibraryAccountIdentity? = nil,
        onShowChats: (() -> Void)? = nil
    ) {
       
        self.importCoordinator = importCoordinator
        self.onOpenBook = onOpenBook
        self.onShowSettings = onShowSettings
        self.onShowChats = onShowChats
        self.onImported = onImported
        self.firstPromptImportAdapter = firstPromptImportAdapter
        self.sharePackageService = sharePackageService
        self.sharedReadingAPI = sharedReadingAPI
        self.sharedReadingRepair = sharedReadingRepair
        self.closeReaderBeforeBookDeletion = closeReaderBeforeBookDeletion
        self.accountIdentity = accountIdentity
        self.externalPath = path
        self.externalDocumentPickerPresented = documentPickerPresented
    }

    public var body: some View {
        @Bindable var vm = vm
        let content = libraryContent(vm: vm)
       
        .libraryDropDestination(coordinator: importCoordinator) { outcomes in

            Task {
                handleImportedAndMarkReaderOpen(outcomes)
                await vm.refresh()
            }
        }

#if canImport(UIKit)
        .sheet(isPresented: documentPickerPresented, onDismiss: {
            firstPromptImportAdapter?.cancelIfStillPicking()
        }) {
            DocumentPickerView { urls in
                let promptAdapter = firstPromptImportAdapter
                if let promptAdapter {
                    guard !urls.isEmpty else {
                        promptAdapter.cancelled()
                        documentPickerPresented.wrappedValue = false
                        return
                    }
                    promptAdapter.began(supportedCount: ImportCoordinator.filterSupported(urls).count)
                }
                documentPickerPresented.wrappedValue = false
                let operationID = UUID()
                activeImportOperationIDs.insert(operationID)
                trialPresentationState.update()
                let importTask = Task {
                    defer {
                        activeImportOperationIDs.remove(operationID)
                        trialPresentationState.update()
                    }
                    let singleSelection = ImportCoordinator.filterSupported(urls).count == 1
                    let onSingleRegistration: (@MainActor @Sendable (ImportCoordinator.ImportOutcome) -> Void)?
                    if singleSelection {
                        onSingleRegistration = { outcome in
                            if let promptAdapter {
                                promptAdapter.registered(outcome)
                                return
                            }
                            let didOpen = onImported?([outcome]) ?? false
                            if didOpen, let book = outcome.book {
                                vm.markImportReaderOpenRequested(bookID: book.id)
                            }
                        }
                    } else {
                        onSingleRegistration = nil
                    }
                    let outcomes = await vm.importPicked(
                        urls,
                        onSingleRegistration: onSingleRegistration
                    )
                    if let promptAdapter {
                        promptAdapter.finished(outcomes)
                    } else if !singleSelection {
                        handleImportedAndMarkReaderOpen(outcomes)
                    }
                }
                promptAdapter?.retainImportTask(importTask)
            }
        }
#endif
        .alert(item: $vm.importError) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Deletion failed", isPresented: Binding(
            get: { vm.deletionError != nil },
            set: { if !$0 { vm.clearDeletionError() } }
        )) {
            Button("OK", role: .cancel) { vm.clearDeletionError() }
        } message: {
            Text(vm.deletionError ?? "The book is still in your library.")
        }
        .task {
            vm.onManagedBookReady = nil
            if let sharePackageService {
                vm.onManagedBookReady = { bookID in
                    Task {
                        guard vm.books.contains(where: { $0.id == bookID }) else { return }
                        await sharePackageService.prewarm(bookIDs: [bookID])
                    }
                }
            }
            await vm.observeImportEvents()
        }
        .onReceive(NotificationCenter.default.publisher(for: SharePackageService.libraryDidChange)) { _ in
            Task { await refreshLibraryAndPrewarm(vm) }
        }
        return addingLibraryCommandNotifications(to: content, vm: vm)
            .onAppear {
                guard trialRegistration == nil, let accountIdentity else { return }
                trialRegistration = trialPresentationState.register(.libraryRoot, identity: accountIdentity) {
                    var safety = TrialChildSafety()
                    safety.signedIn = true
                    safety.consent = true
                    safety.conversation = true
                    safety.voice = true
                    safety.libraryReady = true
                    safety.libraryModal = !documentPickerPresented.wrappedValue
                        && vm.importError == nil
                        && vm.deletionError == nil
                        && activeImportOperationIDs.isEmpty
                        && activeDeletionOperationIDs.isEmpty
                        && !selectionMode
                        && !showShareComposer
                        && !showSharedReadingComposer
                        && !showSharedReadingSwitchConfirmation
                        && pendingCreatorInvitation == nil
                        && (externalPath?.wrappedValue.isEmpty ?? true)
                        && router.sharedReaderRoute == nil
                    safety.firstBookFlowActive = false
                    return safety
                }
                trialPresentationState.update()
            }
            .onDisappear {
                guard let trialRegistration else { return }
                trialPresentationState.unregister(
                    trialRegistration,
                    deferredUnderCover: trialPresentationState.activeOwnedCoverClaimID
                )
                self.trialRegistration = nil
            }
            .onChange(of: documentPickerPresented.wrappedValue) { _, _ in trialPresentationState.update() }
            .onChange(of: vm.importError?.id) { _, _ in trialPresentationState.update() }
            .onChange(of: vm.deletionError) { _, _ in trialPresentationState.update() }
            .onChange(of: selectionMode) { _, _ in trialPresentationState.update() }
            .onChange(of: showShareComposer) { _, _ in trialPresentationState.update() }
            .onChange(of: showSharedReadingComposer) { _, _ in trialPresentationState.update() }
            .onChange(of: showSharedReadingSwitchConfirmation) { _, _ in trialPresentationState.update() }
            .onChange(of: pendingCreatorInvitation?.sessionID) { _, _ in trialPresentationState.update() }
            .onChange(of: router.sharedReaderRoute) { _, _ in trialPresentationState.update() }
            .onChange(of: activeImportOperationIDs) { _, _ in trialPresentationState.update() }
            .onChange(of: activeDeletionOperationIDs) { _, _ in trialPresentationState.update() }
    }

    private func addingLibraryCommandNotifications<Content: View>(
        to content: Content,
        vm: LibraryViewModel
    ) -> some View {
        content
        .onReceive(
            NotificationCenter.default.publisher(
                for: LibraryMacCommandNotification.importBook
            )
        ) { _ in handleImportBookCommand() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: LibraryMacCommandNotification.focusSearch
            )
        ) { _ in
            vm.searchText = ""
        }
    }

    
    
    @ViewBuilder
    private func libraryContent(vm: LibraryViewModel) -> some View {
        @Bindable var vm = vm
        LibraryView(
            books: vm.searchText.isEmpty ? vm.books : vm.filteredBooks,
            readingNow: vm.readingNow,
            libraryBookCount: vm.books.count,
            positionLookup: { bookID in vm.position(for: bookID) },
            coverURL: { book in vm.coverURLs[book.id] },
            onOpen: onOpenBook,
            onDelete: { book in
                guard let deletion = vm.beginDeletion(book) else { return }
                selectedBookIDs.remove(book.id)
                let operationID = UUID()
                activeDeletionOperationIDs.insert(operationID)
                trialPresentationState.update()
                Task {
                    defer {
                        activeDeletionOperationIDs.remove(operationID)
                        trialPresentationState.update()
                    }
                    await vm.completeDeletion(deletion, closePresentedReader: closeReaderBeforeBookDeletion)
                }
            },
            selectionMode: selectionMode,
            selectedBookIDs: eligibleSelectedBookIDs,
            onBeginSelection: { book in
                selectionMode = true
                selectedBookIDs.insert(book.id)
            },
            onToggleSelection: { book in
                if selectedBookIDs.contains(book.id) {
                    selectedBookIDs.remove(book.id)
                } else {
                    selectedBookIDs.insert(book.id)
                }
            },
            onShareSingle: { book in
                beginShare(ids: [book.id], kind: .single)
            },
            onStartSharedReading: { book in
                beginSharedReading(ids: [book.id], books: [book])
            },
            onGridBookVisibilityChange: { bookID, visible in
                vm.setGridBookVisible(bookID, visible: visible)
            },
            onReadingNowBookVisibilityChange: { bookID, visible in
                vm.setReadingNowBookVisible(bookID, visible: visible)
            }
        )

#if DEBUG
        // Keep the E2E start action in the library content hierarchy instead
        // of the Catalyst toolbar. Toolbar items can disappear from the
        // accessibility tree when their state changes after an async import.
        .overlay(alignment: .topTrailing) {
            if RishiE2EConfiguration.isRealAuth {
                Button("Start shared reading") {
                    guard let firstBook = vm.books.first else { return }
                    beginSharedReading(ids: [firstBook.id], books: vm.books)
                }
                .disabled(vm.books.isEmpty)
                .accessibilityIdentifier("e2e-start-shared-reading")
                .padding()
            }
        }
#endif

        .librarySearchable(
            text: $vm.searchText,
            filteredIsEmpty: !vm.searchText.isEmpty && vm.filteredBooks.isEmpty
        )
        .toolbar {
            sharingToolbar(vm: vm)


            ToolbarItem(placement: .primaryAction) {
                    #if DEBUG
                    if RishiE2EConfiguration.isRealAuth {
                        if RishiE2EConfiguration.fixtureURL != nil {
                            Button("Import shared-reading book") {
                                guard let fixtureURL = RishiE2EConfiguration.fixtureURL else { return }
                                let operationID = UUID()
                                activeImportOperationIDs.insert(operationID)
                                trialPresentationState.update()
                                Task {
                                    defer {
                                        activeImportOperationIDs.remove(operationID)
                                        trialPresentationState.update()
                                    }
                                    let outcomes = await vm.importPicked([fixtureURL])
                                    handleImportedAndMarkReaderOpen(outcomes)
                                }
                            }
                            .accessibilityIdentifier("e2e-import-shared-reading-book")
                        }
                    }
                    #endif
                    if ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1" {
                        Button {
                            documentPickerPresented.wrappedValue = true
                        } label: {
                            Label("Import", systemImage: "plus")
                        }
                    } else {
                        Button {
                            documentPickerPresented.wrappedValue = true
                        } label: {
                            Label("Import", systemImage: "plus")
                        }
                        .popoverTip(importTip)
                    }



            }

            #if os(iOS) && !targetEnvironment(macCatalyst)

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onShowChats?()
                    } label: {
                        Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("library.toolbar.chats")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onShowSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            #endif

        }
        .sheet(isPresented: $showShareComposer) {
            shareComposerContent()
        }
        .sheet(isPresented: $showSharedReadingComposer, onDismiss: finishSharedReadingComposerDismissal) {
            if let sharedReadingAPI, let sharedReadingBook {
                SharedReadingShareComposerView(
                    api: sharedReadingAPI,
                    bookId: sharedReadingBook.id.uuidString,
                    bookTitle: sharedReadingBook.title,
                    repairBook: sharedReadingRepair.map { repair in
                        { await repair(sharedReadingBook.id) }
                    },
                    onCreated: { invitation in
                        guard showSharedReadingComposer else { return }
                        pendingCreatorInvitation = invitation
                    }
                )
            }
        }
        .confirmationDialog(
            "Already in a reading session",
            isPresented: $showSharedReadingSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stay in current session", role: .cancel) {
                pendingSharedReadingBook = nil
            }
            Button("Leave and start new") {
                let book = pendingSharedReadingBook
                pendingSharedReadingBook = nil
                if let book { presentSharedReadingComposer(for: book) }
            }
        } message: {
            Text("Your current room will stay open while the new one starts. Other readers can continue after you leave.")
        }
    }

    @ToolbarContentBuilder
    private func sharingToolbar(vm: LibraryViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if selectionMode {
                Button("Share \(eligibleSelectedBookIDs.count)") {
                    beginShare(ids: Array(eligibleSelectedBookIDs), kind: .selection)
                }
                .disabled(eligibleSelectedBookIDs.isEmpty || sharePackageService == nil)
            } else {
                Button {
                    beginShare(ids: vm.books.map(\.id), kind: .library)
                } label: {
                    Label("Share Library", systemImage: "books.vertical")
                }
                .disabled(vm.books.isEmpty || sharePackageService == nil)
            }
        }

        if selectionMode {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") {
                    selectionMode = false
                    selectedBookIDs.removeAll()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Start reading") {
                    beginSharedReading(ids: Array(eligibleSelectedBookIDs), books: vm.books)
                }
                .disabled(eligibleSelectedBookIDs.count != 1 || sharedReadingAPI == nil)
            }
        }
    }

    @ViewBuilder
    private func shareComposerContent() -> some View {
        if let sharePackageService {
            ShareComposerView(
                service: sharePackageService,
                bookIDs: shareBookIDs,
                kind: shareKind,
                onCompleted: {
                    selectionMode = false
                    selectedBookIDs.removeAll()
                }
            )
        }
    }

    private var eligibleSelectedBookIDs: Set<BookID> {
        selectedBookIDs.intersection(Set(vm.books.map(\.id)))
    }

    private func beginShare(ids: [BookID], kind: ShareKind) {
        let visibleIDs = Set(vm.books.map(\.id))
        let ids = ids.filter { visibleIDs.contains($0) }
        guard !ids.isEmpty, sharePackageService != nil else { return }
        shareBookIDs = ids
        shareKind = kind
        showShareComposer = true
    }

    private func beginSharedReading(ids: [BookID], books: [Book]) {
        let visibleIDs = Set(vm.books.map(\.id))
        let ids = ids.filter { visibleIDs.contains($0) }
        guard ids.count == 1, let id = ids.first, let book = books.first(where: { $0.id == id }), sharedReadingAPI != nil else { return }
        if router.hasActiveSharedReader {
            pendingSharedReadingBook = book
            showSharedReadingSwitchConfirmation = true
            return
        }
        presentSharedReadingComposer(for: book)
    }

    private func presentSharedReadingComposer(for book: Book) {
        guard vm.books.contains(where: { $0.id == book.id }) else { return }
        pendingCreatorInvitation = nil
        sharedReadingBook = book
        showSharedReadingComposer = true
    }

    private func finishSharedReadingComposerDismissal() {
        sharedReadingBook = nil
        guard let invitation = pendingCreatorInvitation else {
            Log.sharedReading(.sessionLifecycle, context: .init(operation: .create, outcome: .skipped))
            return
        }
        pendingCreatorInvitation = nil
        Log.sharedReading(.sessionLifecycle, context: .init(operation: .create, outcome: .completed, sessionID: invitation.sessionID))
        AppRouter.enqueueCreatedSession(invitation)
    }

}

private actor LibraryRootPreviewBookStore: BookStore {
    private var byId: [BookID: Book] = [:]

    init(seed: [Book]) {
        for b in seed { byId[b.id] = b }
    }

    func books(for userId: UserID) async throws -> [Book] {
        byId.values.filter { book in book.userId == userId }.sorted {
            left,
            right in left.title < right.title
        }
    }

    func book(_ id: BookID) async throws -> Book? { byId[id] }

    func upsert(_ book: Book) async throws { byId[book.id] = book }

    func delete(_ id: BookID) async throws { byId[id] = nil }
}

private actor LibraryRootPreviewPositionStore: PositionStore {
    private var byBook: [BookID: Position] = [:]

    init(seed: [Position]) {
        for p in seed { byBook[p.bookId] = p }
    }

    func position(for bookId: BookID) async throws -> Position? {
        byBook[bookId]
    }

    func upsert(_ position: Position) async throws {
        byBook[position.bookId] = position
    }

    func delete(_ id: PositionID) async throws {
        if let key = byBook.first(where: { entry in entry.value.id == id })?.key
        {
            byBook[key] = nil
        }
    }
}

@MainActor
enum LibraryRootPreviewFixtures {
    static let userId: UserID = UUID()

    static func book(_ title: String, author: String? = "Preview Author")
        -> Book
    {
        Book(
            id: UUID(),
            userId: userId,
            title: title,
            author: author,
            formatType: .epub,
            fileURL: "Books/\(UUID().uuidString)/\(title).epub"
        )
    }

    static let populated: [Book] = [
        book("Project Hail Mary", author: "Andy Weir"),
        book("Sapiens", author: "Yuval Noah Harari"),
        book("The Pragmatic Programmer", author: "Hunt and Thomas"),
        book("Norwegian Wood", author: "Haruki Murakami"),
        book(
            "Designing Data-Intensive Applications",
            author: "Martin Kleppmann"
        ),
        book("Dune", author: "Frank Herbert"),
    ]

    static func positions(for books: [Book]) -> [Position] {
        books.prefix(2).map { b in
            Position(
                id: UUID(),
                bookId: b.id,
                locator: "{\"page\":1}",
                percentComplete: 0.4,
                updatedAt: Date()
            )
        }
    }

    static func makeViewModel(books: [Book]) -> LibraryViewModel {
        let bookStore = LibraryRootPreviewBookStore(seed: books)
        let positionStore = LibraryRootPreviewPositionStore(
            seed: positions(for: books)
        )
        let tmp = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "RishiLibraryPreview-\(UUID().uuidString)",
            isDirectory: true
        )
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: bookStore,
            coverExtractors: [:]
        )
        let capturedUserId = userId
        let vm = LibraryViewModel(
            bookStore: bookStore,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(
                storage: storage,
                currentUserId: { capturedUserId },
                lifecycle: nil
            ),
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(storage: storage),
            deleteBook: { book in try await storage.delete(book) }
        )
        return vm
    }

    static func makeImportCoordinator() -> ImportCoordinator {
        let bookStore = LibraryRootPreviewBookStore(seed: [])
        let tmp = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "RishiLibraryPreviewImport-\(UUID().uuidString)",
            isDirectory: true
        )
        let storage = BookFileStorage(
            rootURL: tmp,
            bookStore: bookStore,
            coverExtractors: [:]
        )
        let capturedUserId = userId
        return ImportCoordinator(
            storage: storage,
            currentUserId: { capturedUserId },
            lifecycle: nil
        )
    }
}

struct ImportBooksTip: Tip {
    var title: Text {
        Text("Bring your library with you")
    }
    
    var message: Text? {
        Text("Import your EPUB and PDF books to read, listen, and chat with them in one place.")
    }
    
    var image: Image? {
        Image(systemName: "square.and.arrow.down")
    }
}
