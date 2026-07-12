#if canImport(UIKit)
import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
import RishiCore
import RishiUIKit
import RishiLogging

/// Applies persisted `[Highlight]` rows as Readium decorations on an EPUB
/// navigator.
///
/// Decoration are built by ``ReaderHighlightDecorationBuilder`` (shared with
/// the PDF path) and applied in ``groupName`` (`"rishi-highlights"`).
public enum EPUBDecorationApplier {

    /// Decoration group key. Alias of
    /// ``ReaderHighlightDecorationBuilder/groupName``.
    public static let groupName = ReaderHighlightDecorationBuilder.groupName

    /// Applies every highlight as a Readium decoration. Skips rows
    /// whose locator or color cannot be decoded (logged at warning).
    public static func apply(highlights: [Highlight], to navigator: EPUBNavigatorViewController) {
        let decorations = ReaderHighlightDecorationBuilder.make(from: highlights)
        navigator.apply(decorations: decorations, in: groupName)
    }
}
#endif
