import Foundation



/// First-run installer that copies the bundled `alice.epub` sample book into
/// the user's library. Gated on a `UserDefaults` flag so the install is
/// strictly one-shot per device install — even if the user later deletes the
/// sample, we do not re-create it.
/// Marked `@unchecked Sendable` because the only stored references are
/// `BookFileStorage` (an actor, Sendable by construction), `UserDefaults`
/// (thread-safe by Apple's contract), and `Bundle` (immutable). No mutable
/// state lives on this type.
public final class SampleBookInstaller: @unchecked Sendable {

    public static let defaultsKey = "rishi.sampleBookInstalled"

    private let storage: BookFileStorage
    private let defaults: UserDefaults
    private let bundle: Bundle

    public init(storage: BookFileStorage,
                defaults: UserDefaults = .standard,
                bundle: Bundle? = nil) {
        self.storage = storage
        self.defaults = defaults
        // `AppResourceBundle.bundle` is package-internal — accept an explicit override for
        // tests, default to the SwiftPM-generated resource bundle.
        self.bundle = bundle ?? AppResourceBundle.bundle
    }

    /// Copies `alice.epub` from the bundled resources into the user's library
    /// and inserts a Book row. No-op if already installed (idempotent via
    /// UserDefaults flag).
    ///
    /// - Parameter ownerId: current user id (the sample book is owned by the
    ///   user who triggered the first-run flow).
    /// - Returns: the inserted Book on first install; nil on subsequent runs
    ///   or when the bundle resource is missing.
    @discardableResult
    public func installIfNeeded(ownerId: UserID) async -> Book? {
        if defaults.bool(forKey: Self.defaultsKey) {
            return nil
        }
        guard let url = bundle.url(forResource: "alice", withExtension: "epub") else {
            Log.event("library.sample.missing", level: .info,
                      data: ["reason": "bundle_lookup_failed"])
            return nil
        }
        do {
            let book = try await storage.importBook(from: url, ownerId: ownerId)
            defaults.set(true, forKey: Self.defaultsKey)
            Log.event("library.sample.installed", level: .info,
                      data: ["bookId": book.id.uuidString])
            return book
        } catch {
            Log.error("library.sample.install_failed", error: error)
            return nil
        }
    }

    public func sampleBook() async throws ->Book?{
        guard let url = bundle.url(forResource: "alice", withExtension: "epub") else {
            Log.event("library.sample.missing", level: .info,
                      data: ["reason": "bundle_lookup_failed"])
            return nil
        }
        let book = try? await storage.importBook(from: url, ownerId: UUID())
        return book
    }
    /// Test seam: reset the install flag.
    public func resetForTesting() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}


 
