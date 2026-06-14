import Testing
@testable import RishiAudio

/// Locks the rule that `AVAudioEngineAdapter.play()` must follow: do not finish
/// the completion stream until the input ended AND every scheduled buffer has
/// completed. The old adapter finished as soon as the input ended, dropping the
/// final buffer completion — TTSEngine never saw the passage end, so read-aloud
/// stopped after one paragraph and did not advance.
@Suite("Playback completion accounting")
struct PlaybackCompletionAccountantTests {

    @Test("does not finish until input ends AND every buffer completes")
    func waitsForLastCompletion() {
        var a = PlaybackCompletionAccountant()
        a.didSchedule()
        a.didSchedule()
        #expect(a.didEndInput() == false, "input ended but no buffers completed yet")
        #expect(a.didComplete() == false, "1 of 2 completed")
        #expect(a.didComplete() == true, "2 of 2 completed -> finish")
    }

    @Test("finishes at input-end when all buffers already completed")
    func finishesWhenAllDoneBeforeInputEnd() {
        var a = PlaybackCompletionAccountant()
        a.didSchedule()
        #expect(a.didComplete() == false, "completed but input not ended yet")
        #expect(a.didEndInput() == true, "input ends with all buffers done -> finish")
    }

    @Test("an empty stream finishes immediately on input end")
    func emptyFinishesOnInputEnd() {
        var a = PlaybackCompletionAccountant()
        #expect(a.didEndInput() == true)
    }

    @Test("a late completion after input-end triggers finish")
    func lateCompletionFinishes() {
        var a = PlaybackCompletionAccountant()
        a.didSchedule()
        a.didSchedule()
        _ = a.didComplete()        // 1/2
        #expect(a.didEndInput() == false, "still one buffer outstanding")
        #expect(a.didComplete() == true, "last buffer completes after input end -> finish")
    }
}
