import Foundation
import USearch

/// Package version marker + USearch link-time probe.
///
/// The static reference to `USearchIndex` proves the USearch dependency
/// is resolved and linked at scaffold time (Plan 25-03). Plan 25-05
/// (`USearchBookSearch`) is the first production consumer; until then
/// the probe keeps the dependency from being silently dead-stripped.
public enum RishiSearchPackage {
    public static let version = "0.1.0-scaffold"

    /// Internal — touches the USearch type so the symbol is referenced
    /// from RishiSearch's binary. Plan 25-05 replaces this with real
    /// index creation/load code; for now its only job is to verify the
    /// SwiftPM resolution succeeded and the module is importable.
    internal static func _usearchVersionProbe() -> String {
        _ = USearchIndex.self
        return version
    }
}
