import Foundation

import ReadiumShared

/// Pure, navigator-free predicate that decides whether the current EPUB reading
/// location is bookmarked.
///
/// Unlike PDF (where a page is an integer and equality is exact), reflowable
/// EPUB has no integer page. Apple Books bookmarks the current top-of-viewport
/// `Locator`. `EPUBBookmarkMatcher` compares the live `Locator` against each
/// saved bookmark's decoded `Locator`:
///
///   1. The hrefs MUST be equal (a bookmark in another resource never matches).
///   2. When both locators carry an integer `locations.position`, that integer
///      is the stable identity — equal positions match. (RESEARCH Open Question
///      3 / Pitfall 4: prefer the Readium `position` integer when present.)
///   3. Otherwise fall back to `locations.progression` within an epsilon, so a
///      re-opened bookmark whose progression drifted by a hair still matches.
///
/// Kept as pure functions over `Locator` fields so the "is this location
/// bookmarked?" decision is unit-testable on the host without instantiating a
/// Readium navigator (the engine glue is verified by the integrated build).
///
/// Each `Bookmark.locator` is an `epub-bmk-v1` JSON string (see
/// ``EPUBBookmarkLocator``). Bookmarks whose locator fails to decode — a
/// malformed string or a PDF (`pdf-bmk-v1`) locator that rode through the same
/// store — decode to `nil` and are silently ignored rather than crashed on, so
/// a mixed-format bookmark set never breaks the EPUB toggle.
public enum EPUBBookmarkMatcher {

    /// Progression-fallback tolerance. Used only when neither locator carries an
    /// integer `position`; positions, when present, are compared exactly.
    public static let progressionEpsilon = 0.01

    /// Decodes the Readium `Locator` from a bookmark's `epub-bmk-v1` locator, or
    /// `nil` when the locator is malformed or belongs to another reader engine.
    public static func locator(of bookmark: Bookmark) -> Locator? {
        (try? EPUBBookmarkLocator.decoded(fromJSONString: bookmark.locator))?.toReadiumLocator()
    }

    /// `true` when `current` and `saved` refer to the same reading location:
    /// same href, and either equal integer `position` (preferred) or
    /// `progression` within ``progressionEpsilon``.
    public static func matches(_ current: Locator, _ saved: Locator) -> Bool {
        guard current.href.isEquivalentTo(saved.href)  else { return false }
        if let currentPosition = current.locations.position,
           let savedPosition = saved.locations.position {
            return currentPosition == savedPosition
        }
        if let currentProgression = current.locations.progression,
           let savedProgression = saved.locations.progression {
            return abs(currentProgression - savedProgression) < progressionEpsilon
        }
        return false
    }

    /// `true` when any bookmark in `bookmarks` decodes to a locator matching
    /// `current` (per ``matches(_:_:)``).
    public static func isBookmarked(current: Locator, in bookmarks: [Bookmark]) -> Bool {
        bookmarks.contains { bookmark in
            locator(of: bookmark).map { matches(current, $0) } ?? false
        }
    }

    /// The first bookmark whose decoded locator matches `current`, for removal,
    /// or `nil`.
    public static func bookmark(matching current: Locator, in bookmarks: [Bookmark]) -> Bookmark? {
        bookmarks.first { bookmark in
            locator(of: bookmark).map { matches(current, $0) } ?? false
        }
    }
}
