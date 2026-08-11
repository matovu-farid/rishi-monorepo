#if canImport(UIKit)
import UIKit

/// Decides whether the on-screen edge page-turn chevrons should show on the
/// Catalyst reader. The call site compile-gates this affordance away on iOS;
/// Catalyst may report either `.pad` or `.mac` depending on its idiom.
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
