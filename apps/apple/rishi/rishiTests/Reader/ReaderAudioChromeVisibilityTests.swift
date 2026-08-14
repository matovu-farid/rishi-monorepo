import CoreGraphics
import Testing
@testable import rishi

@Suite("ReaderAudioChrome visibility")
struct ReaderAudioChromeVisibilityTests {

    @Test("voice overlay visible when isPresenting even without prior TTS")
    func voiceOnlyShowsChrome() {
        #expect(ReaderAudioChromeVisibility.shouldShow(voiceActive: true, ttsVisible: false))
    }

    @Test("overlay hidden when neither voice nor TTS active")
    func hiddenWhenIdle() {
        #expect(ReaderAudioChromeVisibility.shouldShow(voiceActive: false, ttsVisible: false) == false)
    }

    @Test("overlay visible for TTS alone")
    func ttsShowsChrome() {
        #expect(ReaderAudioChromeVisibility.shouldShow(voiceActive: false, ttsVisible: true))
    }
}

@Suite("Reader audio chrome content inset")
struct ReaderAudioChromeContentInsetTests {

    @Test("visible EPUB reserves the measured player height")
    func visibleEPUBReservesMeasuredHeight() {
        #expect(
            ReaderAudioChromeContentInset.bottomInset(
                defaultBottom: 62,
                safeAreaBottom: 34,
                reservedPlayerHeight: 184
            ) == 246
        )
    }

    @Test("hidden audio chrome releases the EPUB reservation")
    func hiddenChromeReleasesReservation() {
        #expect(
            ReaderAudioChromeContentInset.bottomInset(
                defaultBottom: 62,
                safeAreaBottom: 34,
                reservedPlayerHeight: 0
            ) == 62
        )
    }

    @Test("baseline and safe-area values remain respected")
    func baselineAndSafeAreaValuesRemainRespected() {
        #expect(
            ReaderAudioChromeContentInset.bottomInset(
                defaultBottom: 62,
                safeAreaBottom: 34,
                reservedPlayerHeight: -1
            ) == 62
        )
        #expect(
            ReaderAudioChromeContentInset.bottomInset(
                defaultBottom: 62,
                safeAreaBottom: 80,
                reservedPlayerHeight: 184
            ) == 264
        )
    }
}
