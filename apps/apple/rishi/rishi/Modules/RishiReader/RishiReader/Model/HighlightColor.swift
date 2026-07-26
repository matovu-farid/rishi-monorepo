import SwiftUI



/// Reader UI surface for `RishiCore.HighlightColor`.
///
/// `HighlightColor` is owned by ``RishiCore`` since Phase 1 — its raw
/// values are the persistence + Phase-7 sync wire format. The reader
/// package only adds presentation (SwiftUI swatch + page-overlay
/// opacity). All swatches route through ``RishiUIKit/RishiColor`` so
/// they read correctly on light / dark / sepia page backgrounds.
///
/// Picker exposes exactly four colors per PDF-05 (`.yellow`, `.pink`,
/// `.green`, `.blue`) — match `RishiCore.HighlightColor.allCases`.
public extension HighlightColor {

    /// Token-backed SwiftUI color. Light + dark variants live in
    /// `RishiUIKit/Resources/Colors.xcassets/highlight*.colorset`.
    var swiftUIColor: Color {
        switch self {
        case .yellow: return RishiColor.highlightYellow
        case .pink:   return RishiColor.highlightPink
        case .green:  return RishiColor.highlightGreen
        case .blue:   return RishiColor.highlightBlue
        }
    }

    /// 35% opacity tint used when drawing highlights on the page
    /// background. Keep constant for visual parity across themes.
    var pageOverlayOpacity: Double { 0.35 }
}
