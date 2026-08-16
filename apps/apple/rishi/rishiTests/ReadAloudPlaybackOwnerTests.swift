import Foundation
import Testing
@testable import rishi

@MainActor
private final class FakePlaybackOwner: ReadAloudPlaybackOwnering {
    var installedHosts: [UUID] = []
    var stoppedHosts: [UUID] = []
    var stopForAccountChangeCalls = 0

    func install(controller: ReadAloudController, host: UUID) async {
        installedHosts.append(host)
    }

    func release(host: UUID) async {
        installedHosts.removeAll { $0 == host }
    }

    func stop(host: UUID) async {
        stoppedHosts.append(host)
        installedHosts.removeAll { $0 == host }
    }

    func stopForAccountChange() async {
        stopForAccountChangeCalls += 1
        installedHosts.removeAll()
    }
}

@Suite("Read aloud playback ownership")
@MainActor
struct ReadAloudPlaybackOwnerTests {
    @Test("account teardown invalidates the shared owner")
    func accountTeardown() async {
        let owner = FakePlaybackOwner()
        await owner.stopForAccountChange()
        #expect(owner.stopForAccountChangeCalls == 1)
        #expect(owner.installedHosts.isEmpty)
    }

    @Test("host stop only tears down the requested host")
    func hostStop() async {
        let owner = FakePlaybackOwner()
        let activeHost = UUID()
        let otherHost = UUID()
        owner.installedHosts = [activeHost, otherHost]

        await owner.stop(host: otherHost)
        #expect(owner.stoppedHosts == [otherHost])
        #expect(owner.installedHosts == [activeHost])
    }
}
