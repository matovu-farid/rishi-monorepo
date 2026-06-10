import Foundation
import RishiCore
import RishiLogging

/// UserDefaults-backed per-book reader settings.
///
/// Keys are namespaced under `<namespace>.<bookId>.<setting>`. Theme
/// raw values are stored as plain String so a quick `defaults read
/// <bundle>` is human-readable during debugging.
///
/// Concurrency: `UserDefaults` is documented thread-safe for the
/// scalar accessors we use here, but it does not conform to
/// `Sendable` in Swift 6 strict concurrency. We mark the class
/// `@unchecked Sendable` because (a) the stored references are
/// immutable lets and (b) `UserDefaults`'s scalar accessors are
/// thread-safe per Apple's docs. Mirrors the same pattern used by
/// `SystemKeychainBackend` (Phase 3) and `SampleBookInstaller`
/// (Phase 4).
public final class UserDefaultsReaderSettingsStore: ReaderSettingsStore, @unchecked Sendable {

    private let defaults: UserDefaults
    private let namespace: String

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = "reader.settings"
    ) {
        self.defaults = defaults
        self.namespace = namespace
    }

    public func theme(for bookId: BookID) async -> ReaderTheme {
        let key = themeKey(bookId)
        guard let raw = defaults.string(forKey: key),
              let theme = ReaderTheme(rawValue: raw) else {
            return .default
        }
        return theme
    }

    public func setTheme(_ theme: ReaderTheme, for bookId: BookID) async {
        defaults.set(theme.rawValue, forKey: themeKey(bookId))
        Log.reader.debug("Persisted reader theme \(theme.rawValue) for book \(bookId.uuidString)")
    }

    private func themeKey(_ bookId: BookID) -> String {
        "\(namespace).\(bookId.uuidString).theme"
    }
}
