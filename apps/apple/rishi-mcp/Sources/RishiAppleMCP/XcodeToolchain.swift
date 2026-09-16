import Foundation

public enum XcodeToolchain {
    private static let commandLineTools = "/Library/Developer/CommandLineTools"

    public static func resolveDeveloperDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        installedDirectories: [String]? = nil,
        isUsable: (String) -> Bool = containsXcodeTools
    ) throws -> String {
        let configured = environment["DEVELOPER_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty, configured != commandLineTools {
            guard isUsable(configured) else { throw NSError(domain: "RishiAppleMCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "DEVELOPER_DIR=\(configured) does not contain Xcode tools (xcodebuild and simctl)"]) }
            return configured
        }
        let candidates = installedDirectories ?? (try? FileManager.default.contentsOfDirectory(atPath: "/Applications"))?.filter { $0.range(of: #"^Xcode(?:-.*)?\.app$"#, options: .regularExpression) != nil }.sorted { left, right in
            if left == "Xcode.app" { return true }; if right == "Xcode.app" { return false }; return left < right
        }.map { "/Applications/\($0)/Contents/Developer" } ?? []
        if let fallback = candidates.first(where: isUsable) { return fallback }
        let active = configured ?? commandLineTools
        throw NSError(domain: "RishiAppleMCP", code: 2, userInfo: [NSLocalizedDescriptionKey: "No usable Xcode developer directory found; active DEVELOPER_DIR=\(active) does not contain Xcode tools. Install Xcode or set DEVELOPER_DIR to an Xcode.app/Contents/Developer directory."])
    }

    public static func containsXcodeTools(_ directory: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(directory)/usr/bin/xcodebuild") && FileManager.default.fileExists(atPath: "\(directory)/usr/bin/simctl")
    }
}

/// Exclusive ownership for one MCP build output directory. The lock remains
/// held while the XCTest bridge is alive, so another MCP process cannot share
/// the same build database.
public final class BuildPathLock: @unchecked Sendable {
    private let lockURL: URL
    private let ownerToken: String
    private var released = false
    private let stateLock = NSLock()

    private init(lockURL: URL, ownerToken: String) {
        self.lockURL = lockURL
        self.ownerToken = ownerToken
    }

    public static func acquire(
        derivedDataPath: String,
        target: AppTarget,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> BuildPathLock {
        let derivedURL = URL(fileURLWithPath: derivedDataPath, isDirectory: true)
        try FileManager.default.createDirectory(at: derivedURL, withIntermediateDirectories: true)
        let lockURL = derivedURL.appendingPathComponent(".rishi-mcp-build.lock", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        } catch {
            throw RegistryError(.driverUnavailable, "derived-data path is already in use: \(derivedDataPath)")
        }
        let ownerToken = UUID().uuidString
        do {
            let metadata = try JSONSerialization.data(withJSONObject: [
                "pid": pid,
                "target": target.rawValue,
                "token": ownerToken,
                "startedAt": ISO8601DateFormatter().string(from: Date())
            ], options: [.sortedKeys])
            try metadata.write(to: lockURL.appendingPathComponent("owner.json"), options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockURL.path)
        } catch {
            try? FileManager.default.removeItem(at: lockURL)
            throw error
        }
        return BuildPathLock(lockURL: lockURL, ownerToken: ownerToken)
    }

    public func release() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        guard ownsLockDirectory() else {
            released = true
            throw RegistryError(.driverUnavailable, "build lock ownership changed; refusing to remove \(lockURL.path)")
        }
        try FileManager.default.removeItem(at: lockURL)
        released = true
    }

    private func ownsLockDirectory() -> Bool {
        guard let data = try? Data(contentsOf: lockURL.appendingPathComponent("owner.json")),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let token = object["token"] as? String else { return false }
        return token == ownerToken
    }

    deinit { try? release() }
}

/// Cross-process lock shared with the native E2E host. It serializes Xcode
/// builds even when callers choose different derived-data directories.
public final class SharedBuildLock: @unchecked Sendable {
    private let lockURL: URL
    private let ownerToken: String
    private let stateLock = NSLock()
    private var released = false

    private init(lockURL: URL, ownerToken: String) {
        self.lockURL = lockURL
        self.ownerToken = ownerToken
    }

    public static func acquire(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SharedBuildLock {
        let configured = environment["RISHI_APPLE_XCODE_BUILD_LOCK_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lockURL: URL
        if let configured, !configured.isEmpty {
            lockURL = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            // Keep this path identical to the standalone capture helper and
            // native E2E host. NSTemporaryDirectory() can differ by process.
            lockURL = URL(fileURLWithPath: "/private/tmp/rishi-apple-xcode-build.lock", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        } catch {
            throw RegistryError(.driverUnavailable, "another Apple build is using the shared build lock: \(lockURL.path)")
        }
        let ownerToken = UUID().uuidString
        do {
            let metadata = try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "token": ownerToken,
                "startedAt": ISO8601DateFormatter().string(from: Date()),
            ], options: [.sortedKeys])
            try metadata.write(to: lockURL.appendingPathComponent("owner.json"), options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockURL.path)
        } catch {
            try? FileManager.default.removeItem(at: lockURL)
            throw error
        }
        return SharedBuildLock(lockURL: lockURL, ownerToken: ownerToken)
    }

    public func release() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        guard ownsLockDirectory() else {
            released = true
            throw RegistryError(.driverUnavailable, "shared build lock ownership changed; refusing to remove \(lockURL.path)")
        }
        try FileManager.default.removeItem(at: lockURL)
        released = true
    }

    private func ownsLockDirectory() -> Bool {
        guard let data = try? Data(contentsOf: lockURL.appendingPathComponent("owner.json")),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let token = object["token"] as? String else { return false }
        return token == ownerToken
    }

    deinit { try? release() }
}
