
















import Testing
import Foundation
import RishiCore
@testable import rishi

@MainActor
@Suite("RishiSceneState codec")
struct SceneRestorationStateTests {

    @Test("Round-trip preserves tab + bookId")
    func roundTrip() {
        let id = UUID()
        let state = RishiSceneState(selectedTab: .chats, openBookId: id)
        let raw = state.encodeForStorage()
        let decoded = RishiSceneState.decodeFromStorage(raw)
        #expect(decoded == state)
    }

    @Test("Round-trip with nil bookId preserves nil")
    func roundTripNilBookId() {
        let state = RishiSceneState(selectedTab: .library, openBookId: nil)
        let raw = state.encodeForStorage()
        let decoded = RishiSceneState.decodeFromStorage(raw)
        #expect(decoded == state)
        #expect(decoded.openBookId == nil)
    }

    @Test("Empty string decodes to default")
    func emptyStringIsDefault() {
        #expect(RishiSceneState.decodeFromStorage("") == .default)
    }

    @Test("Garbage decodes to default")
    func garbageIsDefault() {
        #expect(RishiSceneState.decodeFromStorage("not json") == .default)
        #expect(RishiSceneState.decodeFromStorage("{\"selectedTab\":\"bogus\"}") == .default)
    }

    @Test("Default state is library tab, no open book")
    func defaultState() {
        let d = RishiSceneState.default
        #expect(d.selectedTab == .library)
        #expect(d.openBookId == nil)
    }

    @Test("Storage keys are the expected stable strings")
    func storageKeys() {
        #expect(RishiSceneState.selectedTabKey == "rishi.scene.selectedTab")
        #expect(RishiSceneState.openBookIdKey  == "rishi.scene.openBookId")
    }
}
