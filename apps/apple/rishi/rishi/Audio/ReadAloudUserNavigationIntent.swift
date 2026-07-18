import Foundation

/// Decides whether a user page turn during Read Aloud should keep speaking or stop.
///
/// Shared by EPUB and PDF (unified `ReaderDestination`).
///
/// Rules while actively speaking:
/// - **Either page set:** page-aware mode. Both pages required; missing peer → stop.
///   Same page → continue without consuming follow credit.
///   Different page → continue only on text continuity + credit.
/// - **Neither page set (EPUB):** continue only on spoken-paragraph continuity + credit.
///
/// Text continuity matches spoken against **any** destination candidate
/// (`destinationParagraphs`). Empty candidates → no match / stop for the text path.
///
/// Not speaking (paused/idle) → always stop.
enum ReadAloudUserNavigationIntent: Equatable, Sendable {
    /// Keep playing. `consumesFollowCredit` is false for same-page PDF continues.
    case continuePlaying(consumesFollowCredit: Bool)
    case stopPlaying

    static func resolve(
        isActivelySpeaking: Bool,
        spokenParagraph: String?,
        destinationParagraphs: [String],
        spokenPage: Int? = nil,
        destinationPage: Int? = nil,
        followCreditRemaining: Int = 1
    ) -> ReadAloudUserNavigationIntent {
        guard isActivelySpeaking else { return .stopPlaying }

        // Any page signal → page-aware path (do not fall through to EPUB text rules).
        if spokenPage != nil || destinationPage != nil {
            guard let spokenPage, let destinationPage else {
                return .stopPlaying
            }
            if spokenPage == destinationPage {
                return .continuePlaying(consumesFollowCredit: false)
            }
            guard matchesAnyDestination(spokenParagraph, destinationParagraphs) else {
                return .stopPlaying
            }
            return continueIfCreditAvailable(followCreditRemaining)
        }

        guard matchesAnyDestination(spokenParagraph, destinationParagraphs) else {
            return .stopPlaying
        }
        return continueIfCreditAvailable(followCreditRemaining)
    }

    private static func continueIfCreditAvailable(_ credit: Int) -> ReadAloudUserNavigationIntent {
        credit > 0
            ? .continuePlaying(consumesFollowCredit: true)
            : .stopPlaying
    }

    private static func matchesAnyDestination(
        _ spokenParagraph: String?,
        _ destinationParagraphs: [String]
    ) -> Bool {
        guard let spoken = normalized(spokenParagraph) else { return false }
        for candidate in destinationParagraphs {
            guard let destination = normalized(candidate) else { continue }
            if paragraphsMatchForContinuation(spoken, destination) {
                return true
            }
        }
        return false
    }

    /// Same block, or one side is a visible fragment of the other (page split /
    /// Readium utterance vs ParagraphChunker drift).
    static func paragraphsMatchForContinuation(_ spoken: String, _ destination: String) -> Bool {
        if spoken == destination { return true }
        let minFragment = 40
        if spoken.count >= minFragment, destination.count >= minFragment {
            if spoken.hasPrefix(destination) || spoken.hasSuffix(destination) { return true }
            if destination.hasPrefix(spoken) || destination.hasSuffix(spoken) { return true }
            if spoken.contains(destination) || destination.contains(spoken) { return true }
        }
        return false
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

/// Spoken-state + generation captured at swipe start so a slow extract cannot
/// resolve against a later utterance.
struct ReadAloudUserNavigationSnapshot: Equatable, Sendable {
    let generation: UInt64
    let isActivelySpeaking: Bool
    let spokenParagraph: String?
    let spokenPage: Int?
    let followCreditRemaining: Int
}
