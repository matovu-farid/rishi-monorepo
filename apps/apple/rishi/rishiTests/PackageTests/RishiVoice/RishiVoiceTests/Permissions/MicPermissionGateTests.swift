@testable import rishi
import Testing
import Foundation


@Suite("SystemMicPermissionGate")
struct MicPermissionGateTests {

    @Test("Already granted: returns .granted without invoking request()")
    func alreadyGrantedSkipsRequest() async {
        let probe = StubProbe(initial: .granted)
        let gate = SystemMicPermissionGate(probe: probe)
        let decision = await gate.request()
        #expect(decision == .granted)
        #expect(probe.requestCalls == 0)
    }

    @Test("Already denied: returns .denied without invoking request()")
    func alreadyDeniedSkipsRequest() async {
        let probe = StubProbe(initial: .denied)
        let gate = SystemMicPermissionGate(probe: probe)
        let decision = await gate.request()
        #expect(decision == .denied)
        #expect(probe.requestCalls == 0)
    }

    @Test("Undetermined + user grants: invokes request() and returns .granted")
    func undeterminedGranted() async {
        let probe = StubProbe(initial: .undetermined, willGrant: true)
        let gate = SystemMicPermissionGate(probe: probe)
        let decision = await gate.request()
        #expect(decision == .granted)
        #expect(probe.requestCalls == 1)
    }

    @Test("Undetermined + user denies: invokes request() and returns .denied")
    func undeterminedDenied() async {
        let probe = StubProbe(initial: .undetermined, willGrant: false)
        let gate = SystemMicPermissionGate(probe: probe)
        let decision = await gate.request()
        #expect(decision == .denied)
        #expect(probe.requestCalls == 1)
    }

    final class StubProbe: AudioApplicationProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var _requestCalls = 0
        private let initial: MicPermissionDecision
        private let willGrant: Bool

        init(initial: MicPermissionDecision, willGrant: Bool = false) {
            self.initial = initial
            self.willGrant = willGrant
        }

        var requestCalls: Int { lock.withLock { _requestCalls } }

        func currentPermission() -> MicPermissionDecision { initial }
        func requestPermission() async -> Bool {
            lock.withLock { _requestCalls += 1 }
            return willGrant
        }
    }
}
