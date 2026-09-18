import Foundation
import XCTest
@testable import RishiE2EHost

#if canImport(Darwin)
import Darwin
#endif

final class RendezvousRelayTests: XCTestCase, @unchecked Sendable {
    func testRelayReturnsExactParticipantProgressSequence() throws {
        #if canImport(Darwin)
        let relay = RendezvousRelayServer(secret: "test-secret")
        let configuration = try relay.start()
        defer { relay.stop() }
        _ = try request([
            "op": "publish", "secret": configuration.secret,
            "runID": "run-progress", "kind": "participant-progress",
            "value": Int64.max - 1,
        ], port: configuration.port)

        XCTAssertEqual(relay.participantProgressSequence(runID: "run-progress"), Int64.max - 1)
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testRelayRejectsBooleanAndFractionalProgressSequences() throws {
        #if canImport(Darwin)
        for value: Any in [true, 2.5] {
            let relay = RendezvousRelayServer(secret: "test-secret")
            let configuration = try relay.start()
            _ = try request([
                "op": "publish", "secret": configuration.secret,
                "runID": "run-progress", "kind": "participant-progress",
                "value": value,
            ], port: configuration.port)
            XCTAssertNil(relay.participantProgressSequence(runID: "run-progress"))
            relay.stop()
        }
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testRegisterRunnerJSONOperationRequiresSecretRunnerReservationAndRunnerKind() throws {
        #if canImport(Darwin)
        let identity = OwnedProcessIdentity(pid: 4242, birthTimeSeconds: 10, birthTimeMicroseconds: 20)
        let recorder = RelayRegistrationRecorder()
        let relay = RendezvousRelayServer(
            secret: "registration-secret",
            processRecorder: recorder,
            liveIdentity: { $0 == identity.pid ? identity : nil }
        )
        let nonce = try relay.reserveRegistration(
            runID: "run-registration", role: .owner, kind: .runner,
            bundleIdentifier: "org.fidexa.rishiUITests"
        )
        let configuration = try relay.start()
        defer { relay.stop() }

        let response = try request([
            "op": "register-runner", "secret": configuration.secret,
            "runID": "run-registration", "kind": "runner", "role": "owner",
            "nonce": nonce, "bundleIdentifier": "org.fidexa.rishiUITests", "pid": 4242,
        ], port: configuration.port)

        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(recorder.registered, [identity])
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testRunnerCallbackAcknowledgesOnlyAfterStableIdentityJournalWrite() throws {
        #if canImport(Darwin)
        let identity = OwnedProcessIdentity(pid: 4252, birthTimeSeconds: 10, birthTimeMicroseconds: 21)
        let recorder = BlockingRelayRegistrationRecorder()
        let reads = LockedInt()
        let relay = RendezvousRelayServer(
            secret: "registration-secret",
            processRecorder: recorder,
            liveIdentity: { pid in reads.increment(); return pid == identity.pid ? identity : nil }
        )
        let nonce = try relay.reserveRegistration(
            runID: "run-blocking", role: .owner, kind: .runner,
            bundleIdentifier: "org.fidexa.rishiUITests"
        )
        let configuration = try relay.start()
        defer { relay.stop() }
        let completed = DispatchSemaphore(value: 0)
        let response = LockedResponse()
        DispatchQueue.global().async {
            defer { completed.signal() }
            response.value = try? self.request([
                "op": "register-runner", "secret": configuration.secret,
                "runID": "run-blocking", "kind": "runner", "role": "owner",
                "nonce": nonce, "bundleIdentifier": "org.fidexa.rishiUITests", "pid": 4252,
            ], port: configuration.port)
        }
        XCTAssertEqual(recorder.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
        recorder.release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(response.value?["ok"] as? Bool, true)
        XCTAssertEqual(recorder.registered, [identity])
        XCTAssertGreaterThanOrEqual(reads.value, 3)
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testAppCallbackConsumesDistinctLaunchNonceAndJournalsBeforeAcknowledgement() throws {
        #if canImport(Darwin)
        let identity = OwnedProcessIdentity(pid: 4262, birthTimeSeconds: 11, birthTimeMicroseconds: 22)
        let recorder = RelayRegistrationRecorder()
        let relay = RendezvousRelayServer(secret: "secret", processRecorder: recorder, liveIdentity: { $0 == 4262 ? identity : nil })
        let runnerNonce = try relay.reserveRegistration(runID: "run-distinct", role: .owner, kind: .runner, bundleIdentifier: "runner")
        let appNonce = try relay.reserveRegistration(runID: "run-distinct", role: .owner, kind: .app, bundleIdentifier: "app")
        XCTAssertNotEqual(runnerNonce, appNonce)
        let configuration = try relay.start()
        defer { relay.stop() }
        let response = try request([
            "op": "register-app", "secret": configuration.secret, "runID": "run-distinct",
            "role": "owner", "kind": "app", "nonce": appNonce,
            "bundleIdentifier": "app", "pid": 4262,
        ], port: configuration.port)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(recorder.registered, [identity])
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testRegisterAppJSONOperationRequiresSecretAppReservationAndAppKind() throws {
        try testAppCallbackConsumesDistinctLaunchNonceAndJournalsBeforeAcknowledgement()
    }

    func testPrepareAppLaunchWireRequestIncludesAcknowledgedRunnerKindAndNonce() throws {
        #if canImport(Darwin)
        let identity = OwnedProcessIdentity(pid: 4272, birthTimeSeconds: 12, birthTimeMicroseconds: 23)
        let relay = RendezvousRelayServer(secret: "secret", liveIdentity: { $0 == 4272 ? identity : nil })
        let runnerNonce = try relay.reserveRegistration(runID: "run-prepare", role: .owner, kind: .runner, bundleIdentifier: "runner")
        _ = try relay.reserveRegistration(runID: "run-prepare", role: .owner, kind: .app, bundleIdentifier: "app")
        let configuration = try relay.start()
        defer { relay.stop() }
        let before = try request([
            "op": "prepare-app-launch", "secret": configuration.secret, "runID": "run-prepare",
            "role": "owner", "kind": "runner", "nonce": runnerNonce,
        ], port: configuration.port)
        XCTAssertEqual(before["ok"] as? Bool, false)
        XCTAssertEqual(try request([
            "op": "register-runner", "secret": configuration.secret, "runID": "run-prepare",
            "role": "owner", "kind": "runner", "nonce": runnerNonce,
            "bundleIdentifier": "runner", "pid": 4272,
        ], port: configuration.port)["ok"] as? Bool, true)
        XCTAssertEqual(try request([
            "op": "prepare-app-launch", "secret": configuration.secret, "runID": "run-prepare",
            "role": "owner", "kind": "runner", "nonce": runnerNonce,
        ], port: configuration.port)["ok"] as? Bool, true)
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testRelayRejectsAppKindOnRunnerEndpointAndRunnerKindOnAppEndpoint() throws {
        #if canImport(Darwin)
        let identity = OwnedProcessIdentity(pid: 4343, birthTimeSeconds: 11, birthTimeMicroseconds: 21)
        let relay = RendezvousRelayServer(
            secret: "registration-secret",
            liveIdentity: { $0 == identity.pid ? identity : nil }
        )
        let runnerNonce = try relay.reserveRegistration(
            runID: "run-kinds", role: .owner, kind: .runner,
            bundleIdentifier: "org.fidexa.rishiUITests"
        )
        let appNonce = try relay.reserveRegistration(
            runID: "run-kinds", role: .owner, kind: .app,
            bundleIdentifier: "org.fidexa.rishi"
        )
        let configuration = try relay.start()
        defer { relay.stop() }

        for body in [
            ["op": "register-runner", "kind": "app", "nonce": runnerNonce, "bundleIdentifier": "org.fidexa.rishiUITests"] as [String: Any],
            ["op": "register-app", "kind": "runner", "nonce": appNonce, "bundleIdentifier": "org.fidexa.rishi"] as [String: Any],
        ] {
            let response = try request(body.merging([
                "secret": configuration.secret, "runID": "run-kinds",
                "role": "owner", "pid": 4343,
            ]) { _, new in new }, port: configuration.port)
            XCTAssertEqual(response["ok"] as? Bool, false)
        }
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testAppCallbackRejectsWrongNonceRoleBundlePIDReuseAndSecondUse() throws {
        #if canImport(Darwin)
        let identity = OwnedProcessIdentity(pid: 4444, birthTimeSeconds: 12, birthTimeMicroseconds: 22)
        let relay = RendezvousRelayServer(
            secret: "registration-secret",
            liveIdentity: { $0 == identity.pid ? identity : nil }
        )
        let nonce = try relay.reserveRegistration(
            runID: "run-app", role: .owner, kind: .app,
            bundleIdentifier: "org.fidexa.rishi"
        )
        let configuration = try relay.start()
        defer { relay.stop() }
        let valid: [String: Any] = [
            "op": "register-app", "secret": configuration.secret,
            "runID": "run-app", "kind": "app", "role": "owner",
            "nonce": nonce, "bundleIdentifier": "org.fidexa.rishi", "pid": 4444,
        ]
        for mutation: [String: Any] in [
            ["nonce": "wrong"], ["role": "participant"],
            ["bundleIdentifier": "org.fidexa.other"], ["pid": 9999],
        ] {
            let response = try request(valid.merging(mutation) { _, new in new }, port: configuration.port)
            XCTAssertEqual(response["ok"] as? Bool, false)
        }
        XCTAssertEqual(try request(valid, port: configuration.port)["ok"] as? Bool, true)
        XCTAssertEqual(try request(valid, port: configuration.port)["ok"] as? Bool, false)
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }
    func testRelayPublishesAndReadsAValueOverLoopback() throws {
        #if canImport(Darwin)
        let relay = RendezvousRelayServer(secret: "test-secret")
        let configuration = try relay.start()
        defer { relay.stop() }

        let base: [String: Any] = [
            "secret": configuration.secret,
            "runID": "run-1",
            "kind": "participant-progress"
        ]
        let publish = try request(base.merging([
            "op": "publish",
            "value": 7
        ]) { _, new in new }, port: configuration.port)
        XCTAssertEqual(publish["ok"] as? Bool, true)

        let read = try request(base.merging(["op": "read"]) { _, new in new }, port: configuration.port)
        XCTAssertEqual(read["ok"] as? Bool, true)
        XCTAssertEqual((read["value"] as? NSNumber)?.int64Value, 7)

        let ready = base.merging([
            "op": "publish",
            "kind": "participant-ready",
            "value": true
        ]) { _, new in new }
        XCTAssertEqual(try request(ready, port: configuration.port)["ok"] as? Bool, true)
        XCTAssertEqual(
            (try request(base.merging(["op": "read"]) { _, new in new }, port: configuration.port)["value"] as? NSNumber)?.int64Value,
            7
        )
        XCTAssertEqual(
            (try request(ready.merging(["op": "read"]) { _, new in new }, port: configuration.port)["value"] as? NSNumber)?.boolValue,
            true
        )

        let otherRun = base.merging([
            "runID": "run-2",
            "op": "publish",
            "value": 99
        ]) { _, new in new }
        XCTAssertEqual(try request(otherRun, port: configuration.port)["ok"] as? Bool, true)
        XCTAssertEqual(
            (try request(base.merging(["op": "read"]) { _, new in new }, port: configuration.port)["value"] as? NSNumber)?.int64Value,
            7
        )
        XCTAssertEqual(
            (try request(otherRun.merging(["op": "read"]) { _, new in new }, port: configuration.port)["value"] as? NSNumber)?.int64Value,
            99
        )
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testStoppingRelayClearsShortLivedValuesBeforeReuse() throws {
        #if canImport(Darwin)
        let relay = RendezvousRelayServer(secret: "test-secret")
        let first = try relay.start()
        let requestBody: [String: Any] = [
            "secret": first.secret,
            "runID": "run-1",
            "kind": "invite",
            "op": "publish",
            "value": "invite-token",
        ]
        XCTAssertEqual(try request(requestBody, port: first.port)["ok"] as? Bool, true)

        relay.stop()
        let second = try relay.start()
        defer { relay.stop() }
        let read = try request([
            "secret": second.secret,
            "runID": "run-1",
            "kind": "invite",
            "op": "read",
        ], port: second.port)

        XCTAssertTrue(read["value"] is NSNull)
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testRelayBoundsDistinctStoredValues() throws {
        #if canImport(Darwin)
        let relay = RendezvousRelayServer(secret: "test-secret")
        let configuration = try relay.start()
        defer { relay.stop() }

        for index in 0..<32 {
            let response = try request([
                "secret": configuration.secret,
                "runID": "run-\(index)",
                "kind": "event",
                "op": "publish",
                "value": index,
            ], port: configuration.port)
            XCTAssertEqual(response["ok"] as? Bool, true)
        }

        let full = try request([
            "secret": configuration.secret,
            "runID": "run-over-cap",
            "kind": "event",
            "op": "publish",
            "value": true,
        ], port: configuration.port)
        XCTAssertEqual(full["ok"] as? Bool, false)
        XCTAssertEqual(full["error"] as? String, RendezvousRelayError.valueStoreFull.localizedDescription)
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    func testLiveInviteUsesRelayMemoryInsteadOfTheManifestFile() async throws {
        #if canImport(Darwin)
        let relay = RendezvousRelayServer(secret: "test-secret")
        let configuration = try relay.start()
        defer { relay.stop() }

        let manifestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-relay-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let account = TestAccount(
            role: .owner,
            email: "owner@example.test",
            password: "password",
            userID: "owner",
            bearerToken: "bearer"
        )
        let manifest = HostRunManifest(
            runID: "run-relay",
            owner: account,
            participant: TestAccount(
                role: .participant,
                email: "participant@example.test",
                password: "password",
                userID: "participant",
                bearerToken: "bearer"
            ),
            fixture: .init(
                role: .owner,
                format: .epub,
                basename: "book.epub",
                sha256: String(repeating: "a", count: 64),
                byteSize: 10
            ),
            manifestPath: manifestURL.path,
            ownerDestination: .catalyst,
            participantDestination: .iPhone17Pro,
            rendezvousPath: manifestURL.appendingPathExtension("invite").path
        )
        try relay.writeManifest(manifest, to: manifestURL)
        let inviteURL = manifestURL.appendingPathExtension("invite")
        let waiter = Task {
            try await relay.waitForInvite(at: inviteURL, timeout: .seconds(2))
        }
        try await Task.sleep(for: .milliseconds(100))
        _ = try request([
            "secret": configuration.secret,
            "runID": "run-relay",
            "kind": "invite",
            "op": "publish",
            "value": "short-lived-invite",
        ], port: configuration.port)

        let invite = try await waiter.value
        XCTAssertEqual(invite, "short-lived-invite")
        let manifestData = try Data(contentsOf: manifestURL)
        XCTAssertFalse(String(decoding: manifestData, as: UTF8.self).contains("short-lived-invite"))
        #else
        throw XCTSkip("The relay requires Darwin sockets.")
        #endif
    }

    #if canImport(Darwin)
    private func request(_ request: [String: Any], port: UInt16) throws -> [String: Any] {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        guard socketFD >= 0 else { throw RendezvousRelayError.bindFailed }
        defer { Darwin.close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        guard connected == 0 else { throw RendezvousRelayError.bindFailed }

        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { throw RendezvousRelayError.invalidRequest }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(socketFD, baseAddress.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw RendezvousRelayError.invalidRequest }
                offset += count
            }
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            guard count > 0 else { throw RendezvousRelayError.invalidRequest }
            responseData.append(buffer, count: count)
            if responseData.contains(10) { break }
        }
        guard let newline = responseData.firstIndex(of: 10),
              let response = try JSONSerialization.jsonObject(with: responseData.prefix(upTo: newline)) as? [String: Any] else {
            throw RendezvousRelayError.invalidRequest
        }
        return response
    }
    #endif
}

private final class RelayRegistrationRecorder: @unchecked Sendable, OwnedProcessRecording {
    private let lock = NSLock()
    private var identities: [OwnedProcessIdentity] = []
    var registered: [OwnedProcessIdentity] { lock.withLock { identities } }
    func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws {}
    func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws {}
    func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws {}
    func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws {}
    func recordCatalystRegisteredIdentity(_ identity: OwnedProcessIdentity, role: TestAccountRole, kind: PendingCatalystLaunch.Kind) throws {
        lock.withLock { identities.append(identity) }
    }
}

private final class BlockingRelayRegistrationRecorder: @unchecked Sendable, OwnedProcessRecording {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var identities: [OwnedProcessIdentity] = []
    var registered: [OwnedProcessIdentity] { lock.withLock { identities } }
    func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws {}
    func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws {}
    func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws {}
    func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws {}
    func recordCatalystRegisteredIdentity(_ identity: OwnedProcessIdentity, role: TestAccountRole, kind: PendingCatalystLaunch.Kind) throws {
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
        lock.withLock { identities.append(identity) }
    }
}

private final class LockedResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any]?
    var value: [String: Any]? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
}
