import Foundation


/// Phase 18 Plan 18-08 (F-P2-01) — `Identifiable` enum driving the single
/// `.sheet(item: $activeSheet)` modifier on each reader screen.
///
/// Replaces the prior chain of `.sheet(isPresented: $showTOC)` /
/// `$showTypography` / `$showTheme` / `$editingHighlight` modifiers with
/// one state machine. Setting one case automatically unsets the others —
/// it is impossible to be in two content-sheet states at once.
///
/// The TTS-controls + TTS-picker cases are present in the enum because
/// they describe the conceptual surface of reader content sheets, but the
/// current wiring keeps the actual TTS sheets mounted from `RootView`
/// (the `rishi` app target owns them). When the TTS sheets migrate down
/// into `RishiReader`, the `.ttsControls` / `.ttsPicker` cases become live
/// without any source-of-truth changes.
///
/// The paywall sheet stays SEPARATE: it is genuinely modal, can fire
/// CONCURRENTLY with these content sheets (e.g. user taps Read Aloud
/// while the theme picker is up → paywall mounts over it), and lives
/// behind its own `PaywallFeature?`-driven `.sheet(item:)` at the app
/// layer. Folding it into `ReaderSheet` would lose that concurrency.
///
/// Each case produces a stable `String` id:
///   - Bare cases use a single string literal — same id on every read.
///   - `.highlightNote(highlight)` keys its id by the underlying
///     `Highlight.id.uuidString`, so re-presenting the editor for the
///     same row does NOT bounce the sheet, while two different rows
///     produce two different ids.
public enum ReaderSheet: Identifiable, Hashable, Sendable {
    /// Table of contents.
    case toc
    /// EPUB-only typography picker (font family / size / line height).
    /// PDF reader screens that receive this case at the `switch` site
    /// should render nothing — PDFKit owns its own typography surface.
    case typography
    /// Reader theme picker (light / sepia / dark).
    case theme
    /// TTS playback controls (play / pause / rate / skip).
    case ttsControls
    /// TTS voice picker.
    case ttsPicker
    /// Per-highlight note editor. The associated `Highlight` keys the
    /// sheet so editing the same row twice in a row does not re-mount.
    case highlightNote(Highlight)
    /// Saved-bookmarks list. Shared across the PDF (37-02) and EPUB (37-03)
    /// readers — both present the engine-agnostic `BookmarksListView` here.
    case bookmarks
    /// In-book full-text search. Shared across the PDF (37-04) and EPUB (37-05)
    /// readers — both present the engine-agnostic `SearchResultsView` here.
    case search

    public var id: String {
        switch self {
        case .toc:                       return "toc"
        case .typography:                return "typography"
        case .theme:                     return "theme"
        case .ttsControls:               return "ttsControls"
        case .ttsPicker:                 return "ttsPicker"
        case .highlightNote(let h):      return "highlightNote.\(h.id.uuidString)"
        case .bookmarks:                 return "bookmarks"
        case .search:                    return "search"
        }
    }
}
