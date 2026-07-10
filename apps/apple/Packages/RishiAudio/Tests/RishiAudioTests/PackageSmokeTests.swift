import Testing
import Foundation
@testable import RishiAudio
import RishiCore

@Suite("RishiAudio package smoke")
struct PackageSmokeTests {

    @Test("Version string is the 1.0.0 release marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiAudio.version == "1.0.0")
    }

    @Test("RishiCore UserID + BookID reachable from the test target")
    func rishiCoreIdsReachable() {
        let userId = UUID()
        let bookId = UUID()
        // Use the typealiases through the symbol — fails to compile if
        // RishiAudio cannot see RishiCore.
        let user: UserID = userId
        let book: BookID = bookId
        #expect(user == userId)
        #expect(book == bookId)
    }

    @Test("RishiAPI SpeechStreamEndpoint.Body shape is the streaming contract")
    func speechEndpointBodyShape() {
        let body = SpeechStreamEndpoint.Body(text: "hello", voice: "alloy", speed: 1.25)
        #expect(body.text == "hello")
        #expect(body.voice == "alloy")
        #expect(body.speed == 1.25)
    }

    @Test("ElevenLabsSpeechStreamEndpoint.Body shape matches the app worker contract")
    func elevenLabsSpeechEndpointBodyShape() {
        let body = ElevenLabsSpeechStreamEndpoint.Body(text: "hello", voice: "alloy", model: "eleven_flash_v2_5", speed: 1.25)
        #expect(body.text == "hello")
        #expect(body.voice == "alloy")
        #expect(body.model == "eleven_flash_v2_5")
        #expect(body.speed == 1.25)
    }
}
