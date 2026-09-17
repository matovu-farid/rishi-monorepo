import Foundation
import XCTest
@testable import RishiE2EHost

#if canImport(Darwin)
import Darwin
#endif

final class RendezvousRelayTests: XCTestCase {
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
