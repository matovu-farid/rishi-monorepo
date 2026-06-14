#if canImport(UIKit)
import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
import RishiCore
import RishiUIKit

/// Builds the single Readium `Decoration` (and the `Locator` behind it) that
/// marks the paragraph currently being read aloud.
///
/// Read-aloud highlights live in their OWN decoration group (`"rishi-tts"`),
/// separate from the user-highlight group (`"rishi-highlights"`) so the two
/// never clobber each other — `apply(decorations:in:)` diffs per group, so
/// each call here replaces the prior TTS decoration without touching saved
/// highlights.
///
/// The locator carries only the resource `href`/`mediaType` plus a
/// `Locator.Text(highlight:)`. Readium's EPUB navigator resolves a text-only
/// locator by searching the rendered resource DOM for the highlight string,
/// which is sufficient to draw the decoration for a paragraph extracted from
/// that same resource.
public enum EPUBReadAloudDecorationBuilder {

    /// Decoration group key for the active read-aloud passage. Distinct from
    /// ``EPUBDecorationApplier/groupName`` so user highlights and the TTS
    /// highlight are diffed independently.
    public static let groupName: DecorationGroup = "rishi-tts"

    /// Stable decoration id — there is only ever one active passage, so reusing
    /// the id makes each `apply` REPLACE rather than accumulate.
    public static let decorationID: Decoration.Id = "rishi-tts-active"

    /// Builds a text-anchored locator for `paragraph` within the resource at
    /// `href`. The returned locator's `text.highlight` equals `paragraph`.
    public static func locator(
        forParagraph paragraph: String,
        href: AnyURL,
        mediaType: MediaType
    ) -> Locator {
        Locator(
            href: href,
            mediaType: mediaType,
            text: Locator.Text(highlight: paragraph)
        )
    }

    /// Builds the active-passage decoration, tinting it with the read-aloud
    /// accent. `isActive: true` so Readium renders the "current" emphasis.
    public static func decoration(
        forParagraph paragraph: String,
        href: AnyURL,
        mediaType: MediaType
    ) -> Decoration {
        Decoration(
            id: decorationID,
            locator: locator(forParagraph: paragraph, href: href, mediaType: mediaType),
            style: .highlight(tint: UIColor(RishiColor.accent), isActive: true)
        )
    }
}
#endif
