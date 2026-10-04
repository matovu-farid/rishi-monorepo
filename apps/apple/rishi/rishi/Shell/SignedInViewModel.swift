

import SwiftUI


@MainActor
@Observable
final class SignedInViewModel {
    var selectedConversation: Conversation?
    var paywallFeature: PaywallFeature?
    var showSettings = false
    private(set) var bookHints: [BookID: Book] = [:]
    private var initialSyncWaveID: UUID?

    func requestPaywall(_ name: String, serverPaidActive: Bool = false) {
        if serverPaidActive,
           name != "narration_exhausted",
           name != "voice_chat_exhausted"
        {
            return
        }
        paywallFeature = PaywallFeature(name: name)
    }
    func dismissPaywall() { paywallFeature = nil }
    func present(conversation: Conversation) {
        selectedConversation = conversation
    }
    func requestSettings() { showSettings = true }
    func hint(_ book: Book) { bookHints[book.id] = book }
    func hint(for id: BookID) -> Book? { bookHints[id] }

    func expectInitialSyncCompletion(waveID: UUID) {
        initialSyncWaveID = waveID
    }

    func shouldRefreshLibraryAfterSyncCompletion(waveID: UUID) -> Bool {
        guard initialSyncWaveID == waveID else { return true }
        initialSyncWaveID = nil
        return false
    }

    func performInitialLibrarySync(
        refresh: () async -> Void,
        sync: () async -> Void
    ) async {
        await refresh()
        await sync()
        await refresh()
    }

    func performInitialLibrarySyncIfConsented(
        consentGranted: Bool,
        refresh: () async -> Void,
        sync: () async -> Void
    ) async {
        await refresh()
        guard consentGranted else { return }
        await sync()
        await refresh()
    }

    func performInitialLibrarySync(
        consent: () -> Bool,
        refresh: () async -> Void,
        sync: () async -> Void
    ) async {
        await performInitialLibrarySyncIfConsented(
            consentGranted: consent(),
            refresh: refresh,
            sync: sync
        )
    }

    func shouldPresentFirstBookPrompt(
        after result: LibraryViewModel.LoadResult,
        hasSeenPrompt: Bool,
        libraryIsEmpty: Bool
    ) -> Bool? {
        guard result == .success else { return nil }
        return !hasSeenPrompt && libraryIsEmpty
    }

    func canContinueInitialLibraryLoad(
        result: LibraryViewModel.LoadResult,
        identity: LibraryAccountIdentity,
        currentIdentity: LibraryAccountIdentity?,
        readiness: LibraryViewModel.LoadReadiness,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && result == .success
            && currentIdentity == identity
            && readiness == .success(identity)
    }

    func revalidateInitialLibraryLoad(
        result: LibraryViewModel.LoadResult,
        identity: LibraryAccountIdentity,
        currentIdentity: @MainActor () -> LibraryAccountIdentity?,
        readiness: @MainActor () -> LibraryViewModel.LoadReadiness,
        isCancelled: @MainActor () -> Bool,
        refresh: @MainActor () async -> Void
    ) async -> Bool {
        guard result == .success,
              !isCancelled(),
              currentIdentity() == identity else { return false }

        if readiness() != .success(identity) {
            await refresh()
        }

        return canContinueInitialLibraryLoad(
            result: result,
            identity: identity,
            currentIdentity: currentIdentity(),
            readiness: readiness(),
            isCancelled: isCancelled()
        )
    }
}
