#if canImport(UIKit)
import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
import RishiCore
import RishiUIKit
import RishiLogging

/// Converts persisted `[Highlight]` rows into Readium `[Decoration]`
/// and applies them to the navigator.
///
/// **Group name** — `"rishi-highlights"` (matches Spike A). Readium
/// diffs decorations within a group on each `apply(...)` call, so
/// the contract is "submit the full current set, every time".
///
/// **Decoration ID** — `Highlight.id.uuidString`. Re-applying the same
/// row replaces (not duplicates) the prior decoration. New rows produce
/// new decorations; deletions disappear when the row is omitted from
/// the next `apply(...)`.
///
/// **Tint** — `UIColor(RishiColor.highlight{Yellow,Pink,Green,Blue})`.
/// Page-overlay opacity matches the PDF convention
/// (``HighlightColor/pageOverlayOpacity``).
public enum EPUBDecorationApplier {

    /// Decoration group key. Stays in sync with the call from
    /// ``EPUBNavigatorCoordinator/applyHighlights(_:)``.
    public static let groupName: DecorationGroup = "rishi-highlights"

    /// Applies every highlight as a Readium decoration. Skips rows
    /// whose locator or color cannot be decoded (logged at warning).
    public static func apply(highlights: [Highlight], to navigator: EPUBNavigatorViewController) {
        let decorations: [Decoration] = highlights.compactMap { highlight in
            guard let wrapper = try? EPUBHighlightLocator.decode(jsonString: highlight.locatorStart),
                  let locator = wrapper.toReadiumLocator() else {
                Log.reader.warning(
                    "Skipping malformed EPUB highlight \(highlight.id.uuidString, privacy: .public)"
                )
                return nil
            }
            return Decoration(
                id: highlight.id.uuidString,
                locator: locator,
                style: .highlight(tint: uiColor(for: highlight.color), isActive: false)
            )
        }
        navigator.apply(decorations: decorations, in: groupName)
    }

    // MARK: - Color routing

    /// Maps the persisted `HighlightColor` to the matching RishiUIKit
    /// asset token. Phase 5 ships these in `RishiUIKit/Resources/Colors.xcassets`
    /// with light + dark variants — feature packages never touch hex literals.
    private static func uiColor(for color: HighlightColor) -> UIColor {
        let tint: UIColor
        switch color {
        case .yellow: tint = UIColor(RishiColor.highlightYellow)
        case .pink:   tint = UIColor(RishiColor.highlightPink)
        case .green:  tint = UIColor(RishiColor.highlightGreen)
        case .blue:   tint = UIColor(RishiColor.highlightBlue)
        }
        return tint.withAlphaComponent(color.pageOverlayOpacity)
    }
}
#endif
