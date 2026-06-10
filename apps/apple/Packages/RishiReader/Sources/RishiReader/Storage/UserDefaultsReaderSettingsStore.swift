import Foundation
import RishiCore
import RishiLogging

/// UserDefaults-backed per-book reader settings.
///
/// Keys are namespaced under `<namespace>.<bookId>.<setting>`:
/// - `<ns>.<id>.theme`              → ReaderTheme.rawValue (String)
/// - `<ns>.<id>.font.family`        → ReaderFontFamily.rawValue (String)
/// - `<ns>.<id>.font.size`          → Double (points, clamped on read)
/// - `<ns>.<id>.font.lineHeight`    → Double (multiplier, clamped on read)
///
/// Theme raw values are stored as plain String so a quick
/// `defaults read <bundle>` is human-readable during debugging.
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

    // MARK: - Theme

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

    // MARK: - Typography

    public func typography(for bookId: BookID) async -> ReaderTypography {
        let famRaw = defaults.string(forKey: fontFamilyKey(bookId))
        let family = famRaw.flatMap(ReaderFontFamily.init(rawValue:)) ?? .default

        let sizeRaw = defaults.object(forKey: fontSizeKey(bookId)) as? Double
        let size = sizeRaw.map(ReaderFontSize.clamped) ?? .default

        let lhRaw = defaults.object(forKey: lineHeightKey(bookId)) as? Double
        let lineHeight = lhRaw.map { ReaderLineHeight(multiplier: $0) } ?? .default

        return ReaderTypography(fontFamily: family, fontSize: size, lineHeight: lineHeight)
    }

    public func setTypography(_ typography: ReaderTypography, for bookId: BookID) async {
        defaults.set(typography.fontFamily.rawValue, forKey: fontFamilyKey(bookId))
        defaults.set(typography.fontSize.points, forKey: fontSizeKey(bookId))
        defaults.set(typography.lineHeight.multiplier, forKey: lineHeightKey(bookId))
        Log.reader.debug("Persisted reader typography for book \(bookId.uuidString): \(typography.fontFamily.rawValue) \(typography.fontSize.points)pt lh=\(typography.lineHeight.multiplier)")
    }

    // MARK: - Keys

    private func themeKey(_ id: BookID) -> String      { "\(namespace).\(id.uuidString).theme" }
    private func fontFamilyKey(_ id: BookID) -> String { "\(namespace).\(id.uuidString).font.family" }
    private func fontSizeKey(_ id: BookID) -> String   { "\(namespace).\(id.uuidString).font.size" }
    private func lineHeightKey(_ id: BookID) -> String { "\(namespace).\(id.uuidString).font.lineHeight" }
}
