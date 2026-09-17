import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Connection details for the loopback relay used by the two UI-test
/// processes. The relay carries only short-lived test coordination values;
/// it never carries bearer tokens or book contents.
public struct RendezvousRelayConfiguration: Sendable, Equatable {
    public let port: UInt16
    public let secret: String

    public init(port: UInt16, secret: String) {
        self.port = port
        self.secret = secret
    }

    public var environment: [String: String] {
        [
            "RISHI_E2E_RENDEZVOUS_HOST": "127.0.0.1",
            "RISHI_E2E_RENDEZVOUS_PORT": String(port),
            "RISHI_E2E_RENDEZVOUS_SECRET": secret,
        ]
    }
}

/// A bounded, local-only JSON request/response relay. It deliberately uses a
/// loopback TCP socket instead of host filesystem paths because an iOS
/// Simulator UI-test process cannot read the macOS host's temporary files.
public final class RendezvousRelayServer: @unchecked Sendable, SharedReadingRendezvous {
    private let lock = NSLock()
    private let stateLock = NSLock()
    private let secret: String
    private var socket: Int32 = -1
    private var values: [String: Data] = [:]
    private let maximumStoredValues = 32

    public init(secret: String = UUID().uuidString.lowercased()) {
        self.secret = secret
    }

    public func start() throws -> RendezvousRelayConfiguration {
        #if canImport(Darwin)
        lock.lock()
        defer { lock.unlock() }
        guard socket < 0 else {
            throw RendezvousRelayError.alreadyStarted
        }

        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw RendezvousRelayError.bindFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else {
            Darwin.close(listener)
            throw RendezvousRelayError.bindFailed
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        guard addressResult == 0, actual.sin_port != 0 else {
            Darwin.close(listener)
            throw RendezvousRelayError.bindFailed
        }

        socket = listener
        let port = UInt16(bigEndian: actual.sin_port)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop(listener)
        }
        return RendezvousRelayConfiguration(port: port, secret: secret)
        #else
        throw RendezvousRelayError.unsupported
        #endif
    }

    public func stop() {
        lock.lock()
        let listener = socket
        socket = -1
        stateLock.lock()
        values.removeAll(keepingCapacity: false)
        stateLock.unlock()
        lock.unlock()
        #if canImport(Darwin)
        if listener >= 0 { Darwin.close(listener) }
        #endif
    }

    deinit { stop() }

    public func writeManifest(_ manifest: HostRunManifest, to url: URL) throws {
        try RendezvousFileStore().writeManifest(manifest, to: url)
    }

    public func waitForInvite(at url: URL, timeout: Duration) async throws -> String {
        let manifestURL = url.pathExtension == "invite" ? url.deletingPathExtension() : url
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let runID = object["runID"] as? String,
              !runID.isEmpty else {
            throw RendezvousError.invalidRecord
        }
        let key = "\(runID)\u{1F}invite"
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let encoded = storedValue(for: key)
            if let encoded,
               let token = try? JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed]) as? String,
               !token.isEmpty {
                return token
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RendezvousError.timedOut
    }

    private func storedValue(for key: String) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return values[key]
    }

    public func removeManifest(at url: URL) throws {
        try RendezvousFileStore().removeManifest(at: url)
    }

    public func removeManifest(at url: URL, rendezvousURL: URL?) throws {
        try RendezvousFileStore().removeManifest(at: url, rendezvousURL: rendezvousURL)
    }

    #if canImport(Darwin)
    private func acceptLoop(_ listener: Int32) {
        while true {
            lock.lock()
            let isCurrent = socket == listener
            lock.unlock()
            guard isCurrent else { return }
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handle(connection)
            }
        }
    }

    private func handle(_ connection: Int32) {
        defer { Darwin.close(connection) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)

        do {
            let request = try readRequest(from: connection)
            let response = try handle(request)
            try writeResponse(response, to: connection)
        } catch let error as RendezvousRelayError {
            try? writeResponse(["ok": false, "error": error.localizedDescription], to: connection)
        } catch {
            try? writeResponse(["ok": false, "error": "invalid relay request"], to: connection)
        }
    }

    private func readRequest(from connection: Int32) throws -> [String: Any] {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(connection, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RendezvousRelayError.invalidRequest }
            data.append(buffer, count: count)
            guard data.count <= 1_048_576 else { throw RendezvousRelayError.requestTooLarge }
            if data.contains(10) { break }
        }
        guard let newline = data.firstIndex(of: 10),
              let object = try JSONSerialization.jsonObject(with: data.prefix(upTo: newline)) as? [String: Any] else {
            throw RendezvousRelayError.invalidRequest
        }
        return object
    }

    private func handle(_ request: [String: Any]) throws -> [String: Any] {
        guard request["secret"] as? String == secret,
              let runID = request["runID"] as? String, !runID.isEmpty,
              let kind = request["kind"] as? String, !kind.isEmpty,
              kind.count <= 128 else {
            throw RendezvousRelayError.unauthorized
        }
        let key = "\(runID)\u{1F}\(kind)"
        switch request["op"] as? String {
        case "publish":
            guard let value = request["value"], JSONSerialization.isValidJSONObject(["value": value]) else {
                throw RendezvousRelayError.invalidRequest
            }
            let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            guard encoded.count <= 64 * 1024 else { throw RendezvousRelayError.valueTooLarge }
            lock.lock()
            guard socket >= 0 else {
                lock.unlock()
                throw RendezvousRelayError.invalidRequest
            }
            stateLock.lock()
            guard values[key] != nil || values.count < maximumStoredValues else {
                stateLock.unlock()
                lock.unlock()
                throw RendezvousRelayError.valueStoreFull
            }
            values[key] = encoded
            stateLock.unlock()
            lock.unlock()
            return ["ok": true]
        case "read":
            lock.lock()
            guard socket >= 0 else {
                lock.unlock()
                throw RendezvousRelayError.invalidRequest
            }
            stateLock.lock()
            let encoded = values[key]
            stateLock.unlock()
            lock.unlock()
            guard let encoded else { return ["ok": true, "value": NSNull()] }
            let value = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
            return ["ok": true, "value": value]
        default:
            throw RendezvousRelayError.invalidRequest
        }
    }

    private func writeResponse(_ response: [String: Any], to connection: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: response)
        data.append(10)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { throw RendezvousRelayError.invalidRequest }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(connection, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RendezvousRelayError.invalidRequest }
                offset += count
            }
        }
    }
    #endif
}

public enum RendezvousRelayError: Error, LocalizedError, Equatable, Sendable {
    case alreadyStarted
    case bindFailed
    case invalidRequest
    case requestTooLarge
    case unauthorized
    case unsupported
    case valueTooLarge
    case valueStoreFull

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: return "The rendezvous relay is already running."
        case .bindFailed: return "The rendezvous relay could not bind to loopback."
        case .invalidRequest: return "The rendezvous relay received an invalid request."
        case .requestTooLarge: return "The rendezvous relay request is too large."
        case .unauthorized: return "The rendezvous relay request was not authorized."
        case .unsupported: return "The rendezvous relay requires Darwin sockets."
        case .valueTooLarge: return "The rendezvous relay value is too large."
        case .valueStoreFull: return "The rendezvous relay value store is full."
    }
}
}
