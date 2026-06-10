import Testing
import Foundation
@testable import RishiAudio
import RishiCore
import RishiAPI

@Suite("RishiAudio package smoke")
struct PackageSmokeTests {

    @Test("Version string is the streamer+decoder marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiAudio.version == "0.3.0-streamer-decoder")
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
}
