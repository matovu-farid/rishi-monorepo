import Foundation




/// First-run installer that copies the bundled `sample.pdf` (a 3-page
/// welcome / how-to-highlight / how-to-add-notes tour) into the user's
/// library. Mirrors `RishiLibrary.SampleBookInstaller`'s alice.epub
/// install — same one-shot UserDefaults flag pattern.
///
/// `@unchecked Sendable` for the same reason as SampleBookInstaller:
/// stored references are `BookFileStorage` (an actor), `UserDefaults`
/// (thread-safe by Apple's contract), and `Bundle` (immutable).
public final class SampleReaderInstaller: @unchecked Sendable {

    public static let defaultsKey = "rishi.samplePdfInstalled"

    private let storage: BookFileStorage
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let onBookImported: (@Sendable (BookID) async -> Void)?

    public init(storage: BookFileStorage,
                defaults: UserDefaults = .standard,
                bundle: Bundle? = nil,
                onBookImported: (@Sendable (BookID) async -> Void)? = nil) {
        self.storage = storage
        self.defaults = defaults
        // `AppResourceBundle.bundle` is package-internal — accept an explicit override
        // for tests, default to the SwiftPM-generated resource bundle.
        self.bundle = bundle ?? AppResourceBundle.bundle
        self.onBookImported = onBookImported
    }

    /// Copies `sample.pdf` from bundled resources into the user's library on
    /// first run. No-op if already installed (idempotent via UserDefaults
    /// flag) or if the bundle resource is missing.
    @discardableResult
    public func installIfNeeded(ownerId: UserID) async -> Book? {
        if defaults.bool(forKey: Self.defaultsKey) {
            return nil
        }
        guard let url = bundle.url(forResource: "sample", withExtension: "pdf") else {
            Log.event("reader.sample.missing", level: .info,
                      data: ["reason": "bundle_lookup_failed"])
            return nil
        }
        do {
            let book = try await storage.importBook(from: url, ownerId: ownerId)
            if let onBookImported {
                await onBookImported(book.id)
            }
            defaults.set(true, forKey: Self.defaultsKey)
            Log.event("reader.sample.installed", level: .info,
                      data: ["bookId": book.id.uuidString])
            return book
        } catch {
            Log.error("reader.sample.install_failed", error: error)
            return nil
        }
    }

    /// Test seam: reset the install flag.
    public func resetForTesting() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
