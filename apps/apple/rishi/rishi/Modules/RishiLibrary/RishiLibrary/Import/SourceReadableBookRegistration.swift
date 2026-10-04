import Foundation

/// Result of registering a selected book while its original file remains a
/// readable source. A copying registration is immediately usable by the
/// reader; managed materialization can finish in the background.
public struct SourceReadableBookRegistration: Sendable {
    public enum State: Sendable, Equatable {
        case copying
        case managed
    }

    public let book: Book
    public let selectedContentHash: String?
    public let state: State
    public let token: BookMaterializationToken?

    public init(book: Book, selectedContentHash: String? = nil, state: State, token: BookMaterializationToken? = nil) {
        self.book = book
        self.selectedContentHash = selectedContentHash?.lowercased()
        self.state = state
        self.token = token
    }
}

/// Retains provider-owned staging until the managed copy is verified and the
/// final transient reader lease has been released.
final class OwnedImportSourceCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let attemptDirectory: URL
    private var materialized = false
    private var sourceOwnerReleased = false
    private var cleaned = false

    init(attemptDirectory: URL) {
        self.attemptDirectory = attemptDirectory
    }

    func markMaterialized() {
        lock.lock()
        materialized = true
        let shouldClean = sourceOwnerReleased && !cleaned
        if shouldClean { cleaned = true }
        lock.unlock()
        if shouldClean { try? FileManager.default.removeItem(at: attemptDirectory) }
    }

    func sourceOwnerDidRelease() {
        lock.lock()
        sourceOwnerReleased = true
        let shouldClean = materialized && !cleaned
        if shouldClean { cleaned = true }
        lock.unlock()
        if shouldClean { try? FileManager.default.removeItem(at: attemptDirectory) }
    }
}

final class OwnedImportSourceDirectoryOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var transferred = Set<URL>()

    func markTransferred(_ directory: URL) {
        lock.lock(); defer { lock.unlock() }
        transferred.insert(directory.standardizedFileURL)
    }

    func wasTransferred(_ directory: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transferred.contains(directory.standardizedFileURL)
    }
}
