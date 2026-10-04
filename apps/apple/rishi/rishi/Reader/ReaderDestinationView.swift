

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

private enum SharedReadingSheet: String, Identifiable {
    case invitation
    case participants

    var id: String { rawValue }
}

struct ReaderDestinationView: View {
    let route: ReaderRoute
    let hint: Book?
    let onRequestPaywall: (String) -> Void
    var pdfViewMode: Binding<PDFViewModeSetting>? = nil
    var readerWindowCloseHandle: ReaderWindowCloseHandle? = nil
    var sharedReadingContext: SharedReadingReaderContext? = nil
    var sharedReadingCoordinator: SharedReadingSessionCoordinator? = nil
    var sharedReadingJoin: SharedReadingJoin? = nil
    var sharedReadingPeerMesh: SharedReadingPeerMesh? = nil
    var sharedReadingLocalUserID: String? = nil

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var servicesEnv
    @Environment(CurrentUserBox.self) private var currentUser
    @State private var startReaderTour = false
    @State private var didResolveReaderTourRequest = false
    @State private var sharedReaderContentReadySessionID: String?
    @State private var isSharedReaderVisible = false
    @State private var pendingInitialInvitationSessionID: String?
    @State private var presentedSharedReadingSheet: SharedReadingSheet?
    @State private var isSharedSessionLeaveConfirmationPresented = false
    @State private var didPresentInitialInvitationForSessionID: String?
    var user:User? {
        if case .signedIn(user: let user) = currentUser.state {
            return user
        }
        return nil
    }

    var body: some View {

        let services = servicesEnv!
        let userId = user!.id
        Group {
            switch route {
            case .epub(let bookId),.pdf(let bookId):
                NavigationLazyBook(
                    bookId: bookId,
                    hint: hint,
                    ownerId: userId,
                    bookStore: services.library.bookStore,
                    readinessKey: sharedReadingContext?.join.response.sessionId
                ) { book in
                    ReaderSourceLeaseHost(book: book, registry: services.library.bookSourceRegistry) { leasedBook, lease, invalidationCleanup in
                        if let dependencies = try? ReaderDestinationDependencies.make(services: services, book: leasedBook, sourceLease: lease) {
                            ReaderDestination(
                                vm: ReaderViewModel.make(
                                    book: leasedBook,
                                    userId: userId,
                                    positionStore: dependencies.positionStore,
                                    sourceLease: lease,
                                    unpackedCache: dependencies.epubUnpackedCache
                                ),
                                dependencies: dependencies,
                                sourceLease: lease,
                                sourceInvalidationCleanup: invalidationCleanup,
                                userId: userId,
                                onRequestPaywall: onRequestPaywall,
                                startReaderTour: startReaderTour,
                                pdfViewMode: pdfViewMode,
                                readerWindowCloseHandle: readerWindowCloseHandle,
                                sharedReadingCoordinator: sharedReadingContext?.coordinator ?? sharedReadingCoordinator,
                                sharedReadingJoin: sharedReadingContext?.join ?? sharedReadingJoin,
                                sharedReadingPeerMesh: sharedReadingContext?.peerMesh ?? sharedReadingPeerMesh,
                                sharedReadingLocalUserID: sharedReadingContext?.localUserID ?? sharedReadingLocalUserID,
                                onCopyShareLink: sharedCopyShareLinkAction,
                                sharedReadingMoreMenuContent: sharedReadingContext.map { context in
                                    AnyView(
                                        SharedReadingReaderMenuContent(
                                    hasInvitation: context.runtime.invitation != nil,
                                    onInvite: { presentSharedInvitation() },
                                    onManageReaders: {
                                        presentedSharedReadingSheet = .participants
                                    },
                                    onLeaveSharedReading: {
                                        // Role is intentionally checked only when the
                                        // static native-menu action is activated.
                                        if context.runtime.isLocalController {
                                            isSharedSessionLeaveConfirmationPresented = true
                                        } else {
                                            leaveSharedReader(context)
                                        }
                                    }
                                        )
                                    )
                                },
                                onFirstContentReady: {
                                    guard let sharedReadingContext else { return }
                                    sharedReaderContentReadySessionID = sharedReadingContext.join.response.sessionId
                                }
                            )
                    // The transient tour request is consumed when this
                    // destination appears. Recreate the destination subtree
                    // after that flag resolves so its @State coordinator,
                    // voice callback, and reader chrome are initialized with
                    // the guided configuration on iOS and Catalyst.
                    .id(readerDestinationIdentity)
                    .toolbar {
                        if let sharedReadingContext {
                            #if targetEnvironment(macCatalyst)
                            if let invitation = sharedReadingContext.runtime.invitation {
                                ToolbarItem(placement: .primaryAction) {
                                    Button {
                                        copyShareLink(invitation.shareURL)
                                    } label: {
                                        Label("Copy share link", systemImage: "doc.on.doc")
                                    }
                                    .accessibilityIdentifier("shared-reading-copy-link")
                                }
                            }
                            #endif
                        }
                    }
                        } else {
                            ContentUnavailableView("Reader unavailable", systemImage: "book.closed", description: Text("This book is no longer available to read."))
                                .onAppear { invalidationCleanup.register {} }
                        }
                    }
                }
            case .unsupportedFormat(let bookId):
                NavigationLazyBook(
                    bookId: bookId,
                    hint: hint,
                    ownerId: userId,
                    bookStore: services.library.bookStore
                ) { book in
                    EpubPlaceholderView(book: book) {
                        #if targetEnvironment(macCatalyst)
                            dismiss()
                        #else
                            if !router.path.isEmpty { router.path.removeLast() }
                        #endif
                    }
                }
            }
        }
        .onAppear {
            isSharedReaderVisible = true
            guard !didResolveReaderTourRequest, let user else { return }
            didResolveReaderTourRequest = true
            startReaderTour = router.takeReaderTour(
                for: route.bookId,
                userID: user.id
            )
        }
        .onDisappear {
            isSharedReaderVisible = false
            pendingInitialInvitationSessionID = nil
            guard let sharedReadingContext else { return }
            leaveSharedReader(sharedReadingContext)
        }
        .sheet(
            item: $presentedSharedReadingSheet,
            onDismiss: presentPendingInitialInvitationIfPossible
        ) { destination in
            if let sharedReadingContext {
                switch destination {
                case .invitation:
                    if let invitation = sharedReadingContext.runtime.invitation {
                        NavigationStack {
                            SharedReadingInvitationSurface(api: sharedReadingContext.runtime.api, invitation: invitation)
                                .padding()
                                .navigationTitle("Invite readers")
                        }
                        .onAppear {
                            didPresentInitialInvitationForSessionID = invitation.sessionID
                            Log.event("sharing.invite.sheet.visible", data: ["session_id": invitation.sessionID])
                        }
                    }
                case .participants:
                    NavigationStack {
                        SharedReadingReaderControlsSurface(runtime: sharedReadingContext.runtime)
                            .navigationTitle("Participants")
                    }
                }
            }
        }
        .confirmationDialog(
            "Leave reading session",
            isPresented: $isSharedSessionLeaveConfirmationPresented
        ) {
            Button("End for everyone", role: .destructive) {
                guard let sharedReadingContext else { return }
                Task {
                    guard await sharedReadingContext.runtime.end() else { return }
                    leaveSharedReader(sharedReadingContext)
                }
            }
            Button("Leave session", role: .destructive) {
                guard let sharedReadingContext else { return }
                leaveSharedReader(sharedReadingContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can end the room for everyone or leave it running.")
        }
        .task(id: initialInvitationPresentationSessionID) {
            guard let sessionID = initialInvitationPresentationSessionID,
                  didPresentInitialInvitationForSessionID != sessionID else { return }
            // The reader's first content callback can precede the navigation
            // animation. Give it time to settle, then leave the sheet open
            // until the reader explicitly dismisses it.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled,
                  initialInvitationPresentationSessionID == sessionID,
                  didPresentInitialInvitationForSessionID != sessionID else { return }
            pendingInitialInvitationSessionID = sessionID
            presentPendingInitialInvitationIfPossible()
        }
    }

    private func presentSharedInvitation() {
        // Manually opening Invite satisfies the pending first-invite prompt.
        pendingInitialInvitationSessionID = nil
        // A manual request can recover a sheet request dropped during a
        // navigation transition without dismissing one that's already shown.
        if presentedSharedReadingSheet == .invitation,
           let sessionID = sharedInvitationPromptSessionID,
           didPresentInitialInvitationForSessionID != sessionID {
            presentedSharedReadingSheet = nil
            Task { @MainActor in
                await Task.yield()
                guard isSharedReaderVisible,
                      sharedInvitationPromptSessionID == sessionID else { return }
                presentedSharedReadingSheet = .invitation
            }
        } else {
            presentedSharedReadingSheet = .invitation
        }
    }

    private func presentPendingInitialInvitationIfPossible() {
        guard presentedSharedReadingSheet == nil,
              isSharedReaderVisible,
              let sessionID = pendingInitialInvitationSessionID,
              sharedInvitationPromptSessionID == sessionID,
              didPresentInitialInvitationForSessionID != sessionID else { return }

        pendingInitialInvitationSessionID = nil
        presentedSharedReadingSheet = .invitation
        Log.event("sharing.invite.sheet.requested", data: ["session_id": sessionID])
    }

    private func leaveSharedReader(_ context: SharedReadingReaderContext) {
        if let routeID = router.sharedReaderRouteID(for: context.runtime) {
            router.closeSharedReader(id: routeID, accountID: context.runtime.accountID)
        } else {
            Task { @MainActor in await context.runtime.leaveAndClose() }
        }
    }

    private func copyShareLink(_ url: URL) {
        #if canImport(UIKit)
        UIPasteboard.general.string = url.absoluteString
        #endif
    }

    private var sharedCopyShareLinkAction: (() -> Void)? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        guard let sharedReadingContext,
              let invitation = sharedReadingContext.runtime.invitation
        else { return nil }
        return { copyShareLink(invitation.shareURL) }
        #endif
    }

    private var sharedInvitationPromptSessionID: String? {
        guard let sharedReadingContext,
              sharedReaderContentReadySessionID == sharedReadingContext.join.response.sessionId,
              sharedReadingContext.runtime.invitation != nil
        else { return nil }
        return sharedReadingContext.join.response.sessionId
    }

    private var initialInvitationPresentationSessionID: String? {
        isSharedReaderVisible ? sharedInvitationPromptSessionID : nil
    }

    /// A normal reader promoted into a shared session must rebuild its reader
    /// integration with the shared coordinator. Keep this identity beneath
    /// the invitation sheet host so that promotion cannot dismiss an invite
    /// that is already on screen.
    private var readerDestinationIdentity: String {
        let sharedSessionID = sharedReadingContext?.join.response.sessionId ?? "normal"
        return "\(startReaderTour)-\(sharedSessionID)"
    }
}

@MainActor
final class ReaderSourceInvalidationCleanup {
    typealias Action = @MainActor () async -> Void

    private var actions: [Action] = []
    private var isPerforming = false
    private var didFinish = false
    private var readinessWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func register(_ action: @escaping Action) {
        guard !didFinish else {
            Task { await action() }
            return
        }
        actions.append(action)
        let pending = readinessWaiters
        readinessWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func perform() async {
        if didFinish { return }
        if isPerforming {
            await withCheckedContinuation { finishWaiters.append($0) }
            return
        }
        isPerforming = true
        while true {
            if actions.isEmpty {
                await withCheckedContinuation { readinessWaiters.append($0) }
            }
            let pending = actions
            actions.removeAll()
            for action in pending { await action() }
            if actions.isEmpty {
                didFinish = true
                isPerforming = false
                let waiters = finishWaiters
                finishWaiters.removeAll()
                waiters.forEach { $0.resume() }
                return
            }
        }
    }
}

private struct ReaderSourceLeaseHost<Content: View>: View {
    let book: Book
    let registry: BookSourceRegistry
    @ViewBuilder let content: (Book, BookSourceLease, ReaderSourceInvalidationCleanup) -> Content
    @State private var lease: BookSourceLease?
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var invalidationCleanup = ReaderSourceInvalidationCleanup()

    var body: some View {
        Group {
            if let lease {
                content(book, lease, invalidationCleanup)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Book source unavailable", systemImage: "doc.questionmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { attempt += 1 }
                }
            } else {
                ProgressView("Opening book…")
            }
        }
        .task(id: loadKey) {
            do {
                lease = nil
                errorMessage = nil
                invalidationCleanup = ReaderSourceInvalidationCleanup()
                lease = try await registry.acquireReadableSource(for: book)
            } catch {
                lease = nil
                errorMessage = "The selected file may have moved or its access may have expired."
            }
        }
        .task(id: lease?.sourceAccessPermit.sourceInstanceID) {
            guard let lease else { return }
            let cleanup = invalidationCleanup
            for await _ in lease.invalidation {
                guard !Task.isCancelled,
                      self.lease?.sourceAccessPermit == lease.sourceAccessPermit else { return }
                await cleanup.perform()
                guard self.lease?.sourceAccessPermit == lease.sourceAccessPermit else { return }
                self.lease = nil
                errorMessage = "The file changed or became unavailable. Retry or reselect the book to continue."
                break
            }
        }
    }

    private var loadKey: String { "\(book.id)-\(attempt)" }
}

private actor ReaderDestinationPreviewPositionStore: PositionStore {
    func position(for bookId: BookID) async throws -> Position? { nil }
    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

@MainActor
private func makeReaderDestinationPreviewViewModel() -> ReaderViewModel {
    let url = AppResourceBundle.bundle.url(forResource: "alice", withExtension: "epub")
        ?? URL(fileURLWithPath: "/dev/null")
    let book = Book(
        userId: UUID(),
        title: "Alice's Adventures in Wonderland",
        author: "Lewis Carroll",
        formatType: .epub,
        fileURL: url.path
    )
    return ReaderViewModel(
        book: book,
        userId: book.userId,
        documentURL: url,
        positionStore: ReaderDestinationPreviewPositionStore()
    )
}

#Preview("Reader destination — EPUB") {
    ReaderScreen(viewModel: makeReaderDestinationPreviewViewModel())
}
