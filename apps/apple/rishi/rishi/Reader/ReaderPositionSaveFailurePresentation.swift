import Foundation
import Observation
import SwiftUI

/// Retains only a finite notice value across reader dismissal, never the
/// reader, source lease or a persistence/retry closure.
@MainActor
@Observable
final class ReaderPositionSaveFailurePresentation {
    struct Notice: Identifiable, Equatable, Sendable {
        let id = UUID()
        let bookID: BookID
        let bookTitle: String
        let identity: LibraryAccountIdentity
        var message: String { "Your latest reading position in \(bookTitle) could not be saved." }
    }

    private(set) var pending: Notice?
    private var lastReported: (bookID: BookID, identity: LibraryAccountIdentity)?

    nonisolated init() {}

    func record(
        _ result: ReaderPositionFlushResult, bookID: BookID, bookTitle: String,
        identity: LibraryAccountIdentity, currentIdentity: LibraryAccountIdentity?
    ) {
        guard identity == currentIdentity else { return }
        if result == .committed || result == .savedPublicationPending {
            if lastReported?.bookID == bookID, lastReported?.identity == identity { lastReported = nil }
            if pending?.bookID == bookID, pending?.identity == identity { pending = nil }
            return
        }
        guard result == .writeFailed else { return }
        // Overlapping background/dismissal drains report the same failure,
        // including when an active root has already claimed its notice.
        guard lastReported?.bookID != bookID || lastReported?.identity != identity else { return }
        lastReported = (bookID, identity)
        pending = Notice(bookID: bookID, bookTitle: bookTitle, identity: identity)
    }

    func take(for identity: LibraryAccountIdentity?, isActive: Bool) -> Notice? {
        guard isActive, let pending else { return nil }
        guard pending.identity == identity else { clear(); return nil }
        self.pending = nil
        return pending
    }

    func clear() { pending = nil; lastReported = nil }
}

/// Mounted on the app root so the alert survives an iOS reader pop or a
/// Catalyst reader-window close. The first active root claims the notice.
struct ReaderPositionSaveFailureAlert: ViewModifier {
    let presentation: ReaderPositionSaveFailurePresentation
    let accountIdentity: LibraryAccountIdentity?
    var onNoticeVisibilityChange: @MainActor (Bool) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @State private var notice: ReaderPositionSaveFailurePresentation.Notice?

    func body(content: Content) -> some View {
        content
            .onChange(of: presentation.pending?.id) { _, _ in takeNotice() }
            .onChange(of: scenePhase) { _, _ in takeNotice() }
            .onChange(of: accountIdentity) { _, identity in
                if notice?.identity != identity { notice = nil }
                onNoticeVisibilityChange(notice != nil)
                takeNotice()
            }
            .onChange(of: notice?.id) { _, _ in onNoticeVisibilityChange(notice != nil) }
            .onDisappear { onNoticeVisibilityChange(false) }
            .task { takeNotice() }
            .alert("Reading position could not be saved", isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil; takeNotice() } }
            )) {
                Button("OK", role: .cancel) { notice = nil; takeNotice() }
            } message: {
                Text(notice?.message ?? "Your latest reading position could not be saved.")
            }
    }

    private func takeNotice() {
        guard notice == nil else { return }
        notice = presentation.take(for: accountIdentity, isActive: scenePhase == .active)
    }
}
