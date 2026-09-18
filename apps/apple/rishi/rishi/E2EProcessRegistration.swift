import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if DEBUG
enum E2EProcessRegistration {
    enum Result: Equatable { case inactive, registered }
    enum RegistrationError: Error { case invalidConfiguration, relayRejected, framingFailure }
    typealias Exchange = (_ request: Data, _ maximumResponseBytes: Int) throws -> Data

    private static let maximumMessageBytes = 1_048_576

    /// Called synchronously from the first line of `rishiApp.init`. A fully
    /// configured live launch cannot construct application state until the
    /// host has durably journaled this exact PID identity and acknowledged it.
    static func blockStartupIfConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        do {
            _ = try registerAppIfConfigured(
                environment: environment,
                pid: getpid(),
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.fidexa.rishi",
                exchange: socketExchange(environment: environment)
            )
        } catch {
            preconditionFailure("Live E2E app registration failed")
        }
    }

    static func registerAppIfConfigured(
        environment: [String: String],
        pid: Int32,
        bundleIdentifier: String,
        exchange: Exchange
    ) throws -> Result {
        let requiredKeys = [
            "RISHI_UITEST", "RISHI_E2E_REAL_AUTH", "RISHI_E2E_RENDEZVOUS_HOST",
            "RISHI_E2E_RENDEZVOUS_PORT", "RISHI_E2E_RENDEZVOUS_SECRET",
            "RISHI_E2E_RUN_ID", "RISHI_E2E_ROLE", "RISHI_E2E_PROCESS_KIND",
            "RISHI_E2E_APP_REGISTRATION_NONCE",
        ]
        guard requiredKeys.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else { return .inactive }
        guard environment["RISHI_UITEST"] == "1",
              environment["RISHI_E2E_REAL_AUTH"] == "1",
              environment["RISHI_E2E_RENDEZVOUS_HOST"] == "127.0.0.1",
              UInt16(environment["RISHI_E2E_RENDEZVOUS_PORT"] ?? "") != nil,
              environment["RISHI_E2E_ROLE"] == "owner",
              environment["RISHI_E2E_PROCESS_KIND"] == "app",
              pid > 0, !bundleIdentifier.isEmpty else {
            throw RegistrationError.invalidConfiguration
        }
        let request: [String: Any] = [
            "op": "register-app",
            "secret": environment["RISHI_E2E_RENDEZVOUS_SECRET"]!,
            "runID": environment["RISHI_E2E_RUN_ID"]!,
            "role": environment["RISHI_E2E_ROLE"]!,
            "kind": "app",
            "nonce": environment["RISHI_E2E_APP_REGISTRATION_NONCE"]!,
            "bundleIdentifier": bundleIdentifier,
            "pid": Int(pid),
        ]
        var requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard requestData.count < maximumMessageBytes else { throw RegistrationError.framingFailure }
        requestData.append(10)
        let responseData = try exchange(requestData, maximumMessageBytes)
        guard responseData.count <= maximumMessageBytes,
              let newline = responseData.firstIndex(of: 10),
              newline == responseData.index(before: responseData.endIndex),
              let response = try JSONSerialization.jsonObject(with: responseData[..<newline]) as? [String: Any],
              response["ok"] as? Bool == true else {
            throw RegistrationError.relayRejected
        }
        return .registered
    }

    private static func socketExchange(environment: [String: String]) -> Exchange {
        { request, maximumResponseBytes in
            #if canImport(Darwin)
            guard let port = UInt16(environment["RISHI_E2E_RENDEZVOUS_PORT"] ?? "") else {
                throw RegistrationError.invalidConfiguration
            }
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw RegistrationError.framingFailure }
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            address.sin_port = port.bigEndian
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw RegistrationError.framingFailure }
            try writeAll(request, to: fd)
            return try readLine(from: fd, maximumBytes: maximumResponseBytes)
            #else
            throw RegistrationError.framingFailure
            #endif
        }
    }

    #if canImport(Darwin)
    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw RegistrationError.framingFailure }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RegistrationError.framingFailure }
                offset += count
            }
        }
    }

    private static func readLine(from fd: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !result.contains(10) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RegistrationError.framingFailure }
            result.append(buffer, count: count)
            guard result.count <= maximumBytes else { throw RegistrationError.framingFailure }
        }
        return result
    }
    #endif
}
#endif
