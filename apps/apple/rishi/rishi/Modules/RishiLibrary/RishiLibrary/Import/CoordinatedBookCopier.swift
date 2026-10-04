import CryptoKit
import Foundation

public struct StagedBookArtifact: Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let byteCount: Int64
    public let version: ManagedFileVersion

    public init(url: URL, sha256: String, byteCount: Int64, version: ManagedFileVersion) {
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.version = version
    }
}

public struct CoordinatedBookCopier: Sendable {
    public enum CopyError: Error, Sendable, Equatable {
        case sourceChanged
        case contentMismatch
        case cancelled
    }

    private static let queue = DispatchQueue(label: "org.fidexa.rishi.book-materialization-copy", qos: .utility, attributes: .concurrent)
    private static let workLimit = DispatchSemaphore(value: 2)

    public init() {}

    /// Copies one selected source into an attempt-owned staging path. The
    /// source lease keeps any security scope alive and its admission remains
    /// held until the provider-coordinated synchronous copy really returns.
    public func copy(
        source: BookSourceLease,
        to stagingURL: URL,
        expectedSHA256: String,
        expectedByteCount: Int64,
        sourceVersion: ManagedFileVersion
    ) async throws -> StagedBookArtifact {
        let admission = try source.effectAuthority.admit(source.sourceAccessPermit)
        defer { admission.release() }

        do {
            try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let artifact = try await Self.copySynchronouslyWhenScheduled(
                sourceURL: source.url,
                stagingURL: stagingURL,
                expectedSHA256: expectedSHA256,
                expectedByteCount: expectedByteCount,
                sourceVersion: sourceVersion
            )
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: stagingURL)
                throw CopyError.cancelled
            }
            return artifact
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private static func copySynchronouslyWhenScheduled(
        sourceURL: URL,
        stagingURL: URL,
        expectedSHA256: String,
        expectedByteCount: Int64,
        sourceVersion: ManagedFileVersion
    ) async throws -> StagedBookArtifact {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                workLimit.wait()
                defer { workLimit.signal() }
                do {
                    continuation.resume(returning: try copySynchronously(
                        sourceURL: sourceURL,
                        stagingURL: stagingURL,
                        expectedSHA256: expectedSHA256,
                        expectedByteCount: expectedByteCount,
                        sourceVersion: sourceVersion
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func copySynchronously(
        sourceURL: URL,
        stagingURL: URL,
        expectedSHA256: String,
        expectedByteCount: Int64,
        sourceVersion: ManagedFileVersion
    ) throws -> StagedBookArtifact {
        guard try CoordinatedSourceProbe.version(at: sourceURL, revision: sourceVersion.materializationRevision) == sourceVersion else {
            throw CopyError.sourceChanged
        }

        var copyError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: stagingURL)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }

        guard try CoordinatedSourceProbe.version(at: sourceURL, revision: sourceVersion.materializationRevision) == sourceVersion,
              let stagedVersion = try CoordinatedSourceProbe.version(at: stagingURL, revision: sourceVersion.materializationRevision) else {
            throw CopyError.sourceChanged
        }
        let (digest, copiedByteCount) = try digestAndByteCount(stagingURL)
        guard copiedByteCount == expectedByteCount,
              stagedVersion.byteCount == copiedByteCount,
              stagedVersion.byteCount == sourceVersion.byteCount,
              digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame,
              try CoordinatedSourceProbe.version(at: stagingURL, revision: sourceVersion.materializationRevision) == stagedVersion,
              try CoordinatedSourceProbe.version(at: sourceURL, revision: sourceVersion.materializationRevision) == sourceVersion else {
            throw CopyError.contentMismatch
        }
        return StagedBookArtifact(url: stagingURL, sha256: digest.lowercased(), byteCount: copiedByteCount, version: stagedVersion)
    }

    private static func digestAndByteCount(_ url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteCount)
    }
}
