import Foundation
import RishiCore
import RishiBilling
import RishiCore
import RishiReader
import RishiSettings

@MainActor
final class ReaderVoiceEntry: ReaderVoicePresenter {

    private let voicePresenter: VoiceSessionPresenter
    private let voiceLanguageProvider: @MainActor () -> VoiceLanguageOption
    //private let entitlementProvider: () async -> EntitlementLevel
    private let onRequestPaywall: (String) -> Void

    init(
        voicePresenter: VoiceSessionPresenter,
        voiceLanguageProvider: @escaping @MainActor () -> VoiceLanguageOption,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self.voicePresenter = voicePresenter
        self.voiceLanguageProvider = voiceLanguageProvider
        self.onRequestPaywall = onRequestPaywall
    }

    func presentVoice(
        bookId: BookID,
        context: ReaderVoiceContext,
        initialQuote: String?
    ) {

        let snapshot = BookContextSnapshot(
            bookId: bookId,
            currentPage: context.currentPage,
            pageText: context.pageText,
            outline: BookOutlineDTO(
                title: context.title,
                author: context.author,
                chapters: context.chapters
            ),
            activeParagraphText: context.activeParagraphText
        )

        Task {
            await voicePresenter.start(
                bookId: bookId,
                language: voiceLanguageProvider().rawValue,
                initialQuote: initialQuote,
                bookContext: snapshot
            )
        }
    }
}
