import Foundation
import Observation





/// `@Observable` so `ReaderDestination` can present `pendingUpgradePrompt` as
/// a `.sheet(item:)` — `presentVoice` itself must stay synchronous and
/// non-throwing to satisfy `ReaderVoicePresenter`, so it cannot return the
/// block reason directly; it publishes it instead.
@MainActor
@Observable
final class ReaderVoiceEntry: ReaderVoicePresenter {
    private let readerSessionIdentity = ReaderSessionIdentity()

    /// Set by `presentVoice` when the tap is intercepted. `ReaderDestination`
    /// observes this to drive its upgrade-prompt sheet; `dismissUpgradePrompt()`
    /// clears it.
    public private(set) var pendingUpgradePrompt: AIFeatureBlockReason?

    /// True while an entitlement refresh + gate check is in flight.
    public private(set) var isCheckingEntitlement = false

    private let voicePresenter: VoiceSessionPresenter
    private let voiceLanguageProvider: @MainActor () -> VoiceLanguageOption

    /// The live entitlement snapshot store (plan 12). `nil` only to keep
    /// `ReaderVoiceEntryLanguageTests.swift`'s 3-arg construction compiling —
    /// production always passes `services.billing.entitlementSnapshotStore`.
    private let entitlementSnapshotStore: EntitlementSnapshotStore?

    private let onRequestPaywall: (String) -> Void

    init(
        voicePresenter: VoiceSessionPresenter,
        voiceLanguageProvider: @escaping @MainActor () -> VoiceLanguageOption,
        entitlementSnapshotStore: EntitlementSnapshotStore? = nil,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self.voicePresenter = voicePresenter
        self.voiceLanguageProvider = voiceLanguageProvider
        self.entitlementSnapshotStore = entitlementSnapshotStore
        self.onRequestPaywall = onRequestPaywall
    }

    func presentVoice(
        bookId: BookID,
        context: ReaderVoiceContext,
        contextProvider: @escaping ReaderVoiceContextProvider,
        initialQuote: String?
    ) {
        Task {
            isCheckingEntitlement = true
            defer { isCheckingEntitlement = false }

            if let reason = entitlementSnapshotStore?.blockReason(for: .voiceChat) {
                pendingUpgradePrompt = reason
                return
            }

            let contextSnapshot = BookContextSnapshot(
                bookId: bookId,
                currentPage: context.currentPage,
                pageText: nil,
                outline: BookOutlineDTO(
                    title: context.title,
                    author: context.author,
                    chapters: context.chapters
                ),
                activeParagraphText: nil
            )

            let currentPageProvider: CurrentPageContextProvider = { @MainActor in
                let latest = try await contextProvider()
                let availability: CurrentPageContextAvailability =
                    latest.pageText?.isEmpty == false ? .available : .noText
                return CurrentPageContextResult(
                    availability: availability,
                    page: latest.currentPage,
                    pageText: latest.pageText,
                    activeParagraphText: latest.activeParagraphText
                )
            }

            await voicePresenter.start(
                bookId: bookId,
                language: voiceLanguageProvider().rawValue,
                initialQuote: initialQuote,
                bookContext: contextSnapshot,
                currentPageProvider: currentPageProvider,
                readerSessionIdentity: readerSessionIdentity
            )
        }
    }

    /// Dismisses the upgrade prompt without starting a session. Reading
    /// continues uninterrupted — this never blocks anything but the AI
    /// feature itself.
    func dismissUpgradePrompt() {
        pendingUpgradePrompt = nil
    }
}
