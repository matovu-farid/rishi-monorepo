import CryptoKit
import Foundation

struct CoordinatedSourceProbe: Sendable {
    struct DataDigest: Sendable, Equatable {
        let sha256: String
        let byteCount: Int64
    }

    struct Result: Sendable, Equatable {
        let sha256: String
        let byteCount: Int64
        let version: ManagedFileVersion
        let metadata: BookMetadata
    }

    enum ProbeError: Error, Sendable {
        case unreadable
        case sourceChanged
        case contentMismatch
    }

    private static let workQueue = DispatchQueue(label: "org.fidexa.rishi.book-probes", qos: .utility, attributes: .concurrent)
    private static let workLimit = DispatchSemaphore(value: 2)

    func probe(
        _ sourceURL: URL,
        materializationRevision: UUID = UUID(),
        metadataExtractor: (any MetadataExtractor)? = nil,
        hashFile: @escaping @Sendable (URL) throws -> String = { try SHA256Hasher().hash(fileURL: $0) }
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            Self.workQueue.async {
                Self.workLimit.wait()
                defer { Self.workLimit.signal() }
                do {
                    continuation.resume(returning: try Self.probeSynchronously(sourceURL, revision: materializationRevision, metadataExtractor: metadataExtractor, hashFile: hashFile))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func copyVerifiedSource(
        _ sourceURL: URL,
        to stagingURL: URL,
        expected: Result,
        hashFile: @escaping @Sendable (URL) throws -> String = { try SHA256Hasher().hash(fileURL: $0) }
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.workQueue.async {
                Self.workLimit.wait()
                defer { Self.workLimit.signal() }
                do {
                    try Self.copyVerifiedSynchronously(sourceURL, to: stagingURL, expected: expected, hashFile: hashFile)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func digestDownloadedData(_ data: Data) async -> DataDigest {
        await withCheckedContinuation { continuation in
            Self.workQueue.async {
                Self.workLimit.wait()
                defer { Self.workLimit.signal() }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                continuation.resume(returning: DataDigest(sha256: digest, byteCount: Int64(data.count)))
            }
        }
    }

    static func version(at url: URL, revision: UUID) throws -> ManagedFileVersion? {
        guard url.isFileURL else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        let volumeID = attributes[.systemNumber] as? NSNumber
        let fileID = attributes[.systemFileNumber] as? NSNumber
        let identifier = volumeID.flatMap { volume in fileID.map { "\(volume):\($0)" } }
        return ManagedFileVersion(
            byteCount: size.int64Value,
            modificationDate: modificationDate,
            fileIdentifier: identifier,
            materializationRevision: revision
        )
    }

    private static func probeSynchronously(_ sourceURL: URL, revision: UUID, metadataExtractor: (any MetadataExtractor)?, hashFile: @Sendable (URL) throws -> String) throws -> Result {
        guard let before = try version(at: sourceURL, revision: revision) else { throw ProbeError.unreadable }
        var digest: String?
        var metadata = BookMetadata()
        var readError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                digest = try hashFile(coordinatedURL)
                if let metadataExtractor {
                    let metadataBox = MetadataBox()
                    let completed = DispatchSemaphore(value: 0)
                    Task.detached(priority: .utility) {
                        metadataBox.value = await metadataExtractor.extractMetadata(from: coordinatedURL)
                        completed.signal()
                    }
                    completed.wait()
                    metadata = metadataBox.value
                }
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let digest, let after = try version(at: sourceURL, revision: revision), before == after else {
            throw ProbeError.sourceChanged
        }
        return Result(sha256: digest, byteCount: after.byteCount, version: after, metadata: metadata)
    }

    private static func copyVerifiedSynchronously(
        _ sourceURL: URL,
        to stagingURL: URL,
        expected: Result,
        hashFile: @Sendable (URL) throws -> String
    ) throws {
        guard let sourceBefore = try version(at: sourceURL, revision: expected.version.materializationRevision),
              sourceBefore == expected.version else { throw ProbeError.sourceChanged }
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
        if let coordinationError { try? FileManager.default.removeItem(at: stagingURL); throw coordinationError }
        if let copyError { try? FileManager.default.removeItem(at: stagingURL); throw copyError }
        do {
            guard let sourceAfter = try version(at: sourceURL, revision: expected.version.materializationRevision),
                  sourceAfter == expected.version,
                  let copiedVersion = try version(at: stagingURL, revision: expected.version.materializationRevision),
                  copiedVersion.byteCount == expected.byteCount,
                  try hashFile(stagingURL).caseInsensitiveCompare(expected.sha256) == .orderedSame else {
                throw ProbeError.contentMismatch
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }
}

private final class MetadataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = BookMetadata()
    var value: BookMetadata {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private struct SHA256Hasher {
    func hash(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
