




import Foundation
import Testing


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

    @Test("hint caches a book by id and reads it back")
    func bookHints() {
        let model = SignedInViewModel()
        let book = Book.fixture()
        model.hint(book)
        #expect(model.hint(for: book.id)?.id == book.id)
    }

    @Test("requestSettings sets the flag")
    func settings() {
        let model = SignedInViewModel()
        #expect(model.showSettings == false)
        model.requestSettings()
        #expect(model.showSettings == true)
    }

    
    
    
    
    
    
    @Test("iOS Settings flow stays wired: requestSettings() flips showSettings")
    func iosSettingsFlowStaysWired() {
        let model = SignedInViewModel()
        #expect(model.showSettings == false)
        model.requestSettings()
        #expect(model.showSettings == true)
    }

    @Test("present(conversation:) sets selectedConversation")
    func presentConversation() {
        let model = SignedInViewModel()
        let convo = Conversation.fixture()
        model.present(conversation: convo)
        #expect(model.selectedConversation?.id == convo.id)
    }

    
    
    
    @Test("performInitialLibrarySync refreshes, syncs, then refreshes again")
    func initialLibrarySyncOrder() async {
        let model = SignedInViewModel()
        let recorder = EventRecorder()
        await model.performInitialLibrarySync(
            refresh: { await recorder.record("refresh") },
            sync: { await recorder.record("sync") }
        )
        #expect(await recorder.events == ["refresh", "sync", "refresh"])
    }

    @Test("initial local refresh runs without consent while sync remains gated")
    func initialLibrarySyncLoadsWithoutConsent() async {
        let model = SignedInViewModel()
        let recorder = EventRecorder()
        var consentGranted = false

        await model.performInitialLibrarySync(
            consent: { consentGranted },
            refresh: { await recorder.record("refresh") },
            sync: { await recorder.record("sync") }
        )
        #expect(await recorder.events == ["refresh"])

        consentGranted = true
        await model.performInitialLibrarySync(
            consent: { consentGranted },
            refresh: { await recorder.record("refresh") },
            sync: { await recorder.record("sync") }
        )

        #expect(await recorder.events == ["refresh", "refresh", "sync", "refresh"])
    }

    @Test("first-book prompt decision requires a successful local snapshot")
    func firstBookPromptRequiresSuccessfulSnapshot() {
        let model = SignedInViewModel()
        #expect(model.shouldPresentFirstBookPrompt(after: .failure, hasSeenPrompt: false, libraryIsEmpty: true) == nil)
        #expect(model.shouldPresentFirstBookPrompt(after: .cancelled, hasSeenPrompt: false, libraryIsEmpty: true) == nil)
        #expect(model.shouldPresentFirstBookPrompt(after: .success, hasSeenPrompt: false, libraryIsEmpty: true) == true)
        #expect(model.shouldPresentFirstBookPrompt(after: .success, hasSeenPrompt: true, libraryIsEmpty: true) == false)
        #expect(model.shouldPresentFirstBookPrompt(after: .success, hasSeenPrompt: false, libraryIsEmpty: false) == false)
    }

    @Test("initial sync suppression follows its delayed completion wave only")
    func initialSyncCompletionDoesNotSuppressLaterWave() {
        let model = SignedInViewModel()
        let initialWaveID = UUID()
        let unrelatedWaveID = UUID()
        model.expectInitialSyncCompletion(waveID: initialWaveID)

        #expect(model.shouldRefreshLibraryAfterSyncCompletion(waveID: unrelatedWaveID))
        #expect(!model.shouldRefreshLibraryAfterSyncCompletion(waveID: initialWaveID))
        #expect(model.shouldRefreshLibraryAfterSyncCompletion(waveID: unrelatedWaveID))
    }

    @Test("stale or canceled prewarm continuation cannot commit library-ready effects")
    func staleInitialLibraryContinuationIsRejected() {
        let model = SignedInViewModel()
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 4)
        let otherIdentity = LibraryAccountIdentity(userID: UUID(), generation: 5)

        #expect(!model.canContinueInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: otherIdentity,
            readiness: .success(identity),
            isCancelled: false
        ))
        #expect(!model.canContinueInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: identity,
            readiness: .success(identity),
            isCancelled: true
        ))
        #expect(!model.canContinueInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: identity,
            readiness: .loading(identity),
            isCancelled: false
        ))
        #expect(model.canContinueInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: identity,
            readiness: .success(identity),
            isCancelled: false
        ))
    }

    @Test("a refresh completing during prewarm resumes initial library readiness")
    func initialLoadRechecksAfterOverlappingRefresh() async {
        let model = SignedInViewModel()
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 9)
        var currentIdentity: LibraryAccountIdentity? = identity
        var readiness: LibraryViewModel.LoadReadiness = .loading(identity)
        var refreshCount = 0

        let ready = await model.revalidateInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: { currentIdentity },
            readiness: { readiness },
            isCancelled: { false },
            refresh: {
                refreshCount += 1
                readiness = .success(identity)
            }
        )

        #expect(ready)
        #expect(refreshCount == 1)
        #expect(readiness == .success(identity))

        readiness = .loading(identity)
        let replacedAccountContinues = await model.revalidateInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: { currentIdentity },
            readiness: { readiness },
            isCancelled: { false },
            refresh: {
                currentIdentity = LibraryAccountIdentity(userID: UUID(), generation: 10)
                readiness = .success(identity)
            }
        )
        #expect(!replacedAccountContinues)
    }

    @Test("library actions remain deferred while the current snapshot is loading")
    func libraryActionsCanResumeAfterLoadingSnapshot() async {
        let model = SignedInViewModel()
        let identity = LibraryAccountIdentity(userID: UUID(), generation: 12)
        var readiness: LibraryViewModel.LoadReadiness = .loading(identity)
        var refreshCount = 0

        let actionCanContinue = await model.revalidateInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: { identity },
            readiness: { readiness },
            isCancelled: { false },
            refresh: {
                refreshCount += 1
            }
        )

        #expect(!actionCanContinue)
        #expect(refreshCount == 1)
        #expect(readiness == .loading(identity))

        readiness = .success(identity)
        let deferredActionCanContinue = await model.revalidateInitialLibraryLoad(
            result: .success,
            identity: identity,
            currentIdentity: { identity },
            readiness: { readiness },
            isCancelled: { false },
            refresh: {}
        )
        #expect(deferredActionCanContinue)
    }
}

private actor EventRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
