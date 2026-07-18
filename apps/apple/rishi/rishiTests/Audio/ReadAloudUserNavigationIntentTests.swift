import Foundation
import Testing
@testable import rishi

@Suite("ReadAloudUserNavigationIntent")
@MainActor
struct ReadAloudUserNavigationIntentTests {

    private let spoken = String(repeating: "Alpha paragraph body that spans pages. ", count: 4)

    @Test("continues when destination opens on the same spoken paragraph")
    func continuesOnSameParagraph() {
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [spoken],
            followCreditRemaining: 1
        )
        #expect(intent == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("continues when destination shows a trailing fragment of the spoken paragraph")
    func continuesOnTrailingFragment() {
        let trailing = String(spoken.suffix(80))
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [trailing],
            followCreditRemaining: 1
        )
        #expect(intent == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("continues when spoken matches a neighbor in the destination window")
    func continuesWhenProgressionAheadNeighborInWindow() {
        let neighbor = String(repeating: "Next chunk after progression jump. ", count: 4)
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [neighbor, spoken],
            followCreditRemaining: 1
        )
        #expect(intent == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("continues when ≥40-char contains matches either way")
    func continuesOnContainsEitherWay() {
        let longer = spoken + " trailing drift from Readium utterance."
        let intentSpokenInDest = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [longer],
            followCreditRemaining: 1
        )
        #expect(intentSpokenInDest == .continuePlaying(consumesFollowCredit: true))

        let intentDestInSpoken = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: longer,
            destinationParagraphs: [spoken],
            followCreditRemaining: 1
        )
        #expect(intentDestInSpoken == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("stops when destination opens on a different paragraph")
    func stopsOnDifferentParagraph() {
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [String(repeating: "Completely different next page. ", count: 4)],
            followCreditRemaining: 1
        )
        #expect(intent == .stopPlaying)
    }

    @Test("stops when not actively speaking even if paragraphs match")
    func stopsWhenPausedOrIdle() {
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: false,
            spokenParagraph: spoken,
            destinationParagraphs: [spoken],
            followCreditRemaining: 1
        )
        #expect(intent == .stopPlaying)
    }

    @Test("stops when destination has no extractable paragraph")
    func stopsWhenDestinationEmpty() {
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [],
            followCreditRemaining: 1
        )
        #expect(intent == .stopPlaying)
    }

    @Test("PDF same-page continue does not require credit")
    func pdfSamePageContinueDoesNotConsumeCredit() {
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: ["ignored when pages match"],
            spokenPage: 3,
            destinationPage: 3,
            followCreditRemaining: 0
        )
        #expect(intent == .continuePlaying(consumesFollowCredit: false))
    }

    @Test("PDF different page with matching fragment continues and consumes credit")
    func pdfDifferentPageMatchingFragmentContinues() {
        let trailing = String(spoken.suffix(80))
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [trailing],
            spokenPage: 2,
            destinationPage: 3,
            followCreditRemaining: 1
        )
        #expect(intent == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("PDF: stops when turning to a different page while speaking")
    func pdfStopsOnDifferentPage() {
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [String(repeating: "Next page body text here. ", count: 4)],
            spokenPage: 3,
            destinationPage: 4,
            followCreditRemaining: 1
        )
        #expect(intent == .stopPlaying)
    }

    @Test("second same-paragraph match stops when follow credit is exhausted")
    func secondMatchStopsWithoutCredit() {
        let first = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [spoken],
            followCreditRemaining: 1
        )
        #expect(first == .continuePlaying(consumesFollowCredit: true))

        let second = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [spoken],
            followCreditRemaining: 0
        )
        #expect(second == .stopPlaying)
    }

    @Test("asymmetric pages stop instead of falling through to text match")
    func asymmetricPagesStop() {
        let withSpokenOnly = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [spoken],
            spokenPage: 2,
            destinationPage: nil,
            followCreditRemaining: 1
        )
        #expect(withSpokenOnly == .stopPlaying)

        let withDestinationOnly = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: true,
            spokenParagraph: spoken,
            destinationParagraphs: [spoken],
            spokenPage: nil,
            destinationPage: 3,
            followCreditRemaining: 1
        )
        #expect(withDestinationOnly == .stopPlaying)
    }
}
