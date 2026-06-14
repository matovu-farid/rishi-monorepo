import Foundation

/// JSON sidecar persistence for `BookSearchStatus` at
/// `<rootURL>/Books/<bookId>/index.status.json`.
///
/// The sidecar is the cold-start contract: `USearchBookSearch.status(bookId:)`
/// reads it before deciding whether `search(...)` can return real hits or
/// must throw `BookContextSearchError.indexNotReady`. `IndexBuilder` writes
/// it at each stage of the build (`.indexing(...)` progress updates, then
/// `.ready` on success, or `.failed(reason:)` on crash).
///
/// File missing → `.notIndexed`. File present but unreadable / corrupted →
/// also `.notIndexed` (treated as "no usable index yet") rather than
/// throwing, because the search path needs a single sentinel to fall back
/// to without exception handling on the read path.
struct IndexStatusStore: Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    /// Read the current status. Returns `.notIndexed` for any read or
    /// decode failure. Never throws.
    func read() -> BookSearchStatus {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .notIndexed
        }
        return envelope.toStatus()
    }

    /// Atomically write the status. Creates intermediate directories as needed.
    func write(_ status: BookSearchStatus) throws {
        let envelope = Envelope(status: status)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Envelope

    /// Stable on-disk JSON shape. Adding new states later means adding a
    /// new `state` string and bumping the reader's switch.
    private struct Envelope: Codable {
        let state: String
        let chunksDone: Int?
        let chunksTotal: Int?
        let reason: String?
        let updatedAt: String

        init(status: BookSearchStatus) {
            self.updatedAt = ISO8601DateFormatter().string(from: Date())
            switch status {
            case .notIndexed:
                self.state = "notIndexed"
                self.chunksDone = nil
                self.chunksTotal = nil
                self.reason = nil
            case let .indexing(done, total):
                self.state = "indexing"
                self.chunksDone = done
                self.chunksTotal = total
                self.reason = nil
            case .ready:
                self.state = "ready"
                self.chunksDone = nil
                self.chunksTotal = nil
                self.reason = nil
            case let .failed(reason):
                self.state = "failed"
                self.chunksDone = nil
                self.chunksTotal = nil
                self.reason = reason
            }
        }

        func toStatus() -> BookSearchStatus {
            switch state {
            case "indexing":
                return .indexing(
                    chunksDone: chunksDone ?? 0,
                    chunksTotal: chunksTotal ?? 0
                )
            case "ready":
                return .ready
            case "failed":
                return .failed(reason: reason ?? "unknown")
            default:
                return .notIndexed
            }
        }
    }
}
