//
//  PremptionTest.swift
//  rishiTests
//
//  Created by Farid Matovu on 28/06/2026.
//

import Testing
import Foundation
import RishiAudio
import RishiVoice


enum PremptionTestError:Error {
    case NoServices
    case NoSession
}
struct PremptionTest {

    @Test  func PremptionStopsPlayBack() async throws {
        let dep = AppDependencies()
        await dep.bootstrap()
        await dep.setUserId(UUID())
        guard let services = await dep.services else {
            throw PremptionTestError.NoServices
        }
        let tracker = TTSPassageTracker()

       // arrange
        let bridge = await ReaderTTSBridge(
            engine: services.ttsEngine,
            state: services.ttsState,
            tracker: tracker,
            prewarmer: services.ttsPrewarmer,
            settingsStore: services.ttsSettingsStore,
            userId: UUID(),
            coordinator: services.audioCoordinator,
            onPassageChange: {_ in})
       // act
        //assert
        
        let voicePresenter = services.voicePresenter
        //let mode = await services.audioCoordinator.currentMode
        await bridge.start(paragraphs: paragraphs)
        #expect(await services.audioCoordinator.currentMode == .tts)
        await voicePresenter.start(bookId: nil)
        #expect(await services.audioCoordinator.currentMode == .voice)
   
        #expect(await bridge.currentState.status == .paused)
        

        
    }

}
