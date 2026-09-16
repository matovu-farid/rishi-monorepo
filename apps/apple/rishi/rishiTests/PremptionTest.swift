@testable import rishi
//
//  PremptionTest.swift
//  rishiTests
//
//  Created by Farid Matovu on 28/06/2026.
//

import Testing
import Foundation




enum PremptionTestError:Error {
    case NoServices
    case NoSession
}
struct PremptionTest {

    @Test  func PremptionStopsPlayBack() async throws {
        let dep = AppDependencies()
        await dep.bootstrap()
        await dep.replaceUserId(UUID())
        guard let services = await dep.services else {
            throw PremptionTestError.NoServices
        }
        let tracker = TTSPassageTracker()

       // arrange
        let bridge = await ReaderTTSBridge(
            engine: services.audio.ttsEngine,
            state: services.audio.ttsState,
            tracker: tracker,
            prewarmer: services.audio.ttsPrewarmer,
            settingsStore: services.audio.ttsSettingsStore,
            userId: UUID(),
            coordinator: services.audio.coordinator,
            onPassageChange: {_ in})
       // act
        //assert
        
        let voicePresenter = services.voice.presenter
        //let mode = await services.audio.coordinator.currentMode
        await bridge.start(paragraphs: paragraphs)
        #expect(await services.audio.coordinator.currentMode == .tts)
        await voicePresenter.start(bookId: nil)
        #expect(await services.audio.coordinator.currentMode == .voice)
   
        #expect(await bridge.currentState.status == .paused)
        

        
    }

}
