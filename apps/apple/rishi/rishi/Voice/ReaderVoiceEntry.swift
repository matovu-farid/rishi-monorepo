import Foundation
import RishiAPI
import RishiBilling
import RishiCore
import RishiReader

@MainActor
final class ReaderVoiceEntry: ReaderVoicePresenter {

    private let voicePresenter: VoiceSessionPresenter
    //private let entitlementProvider: () async -> EntitlementLevel
    private let onRequestPaywall: (String) -> Void

    init(
        voicePresenter: VoiceSessionPresenter,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self.voicePresenter = voicePresenter
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
                initialQuote: initialQuote,
                bookContext: snapshot
            )
        }
    }
}
