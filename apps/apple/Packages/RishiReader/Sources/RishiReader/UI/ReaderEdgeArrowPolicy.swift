#if canImport(UIKit)
import UIKit

/// Decides whether the on-screen edge page-turn chevrons should show.
/// Shown on iPad and Mac (Catalyst reports `.pad`, or `.mac` when the
/// app is built with the Mac idiom); hidden on iPhone and everything else.
public struct ReaderEdgeArrowPolicy: Sendable {
    public init() {}
    public static func shouldShow(idiom: UIUserInterfaceIdiom) -> Bool {
        switch idiom {
        case .pad, .mac: return true
        default: return false
        }
    }
}
#endif
