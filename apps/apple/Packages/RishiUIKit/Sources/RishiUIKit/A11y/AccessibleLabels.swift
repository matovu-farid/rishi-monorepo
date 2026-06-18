import SwiftUI

/// Shared VoiceOver label strings. Pulled from a single enum so reader,
/// chat, and library use the same vocabulary — and so the strings are easy
/// to localise from one place.
///
/// Values are plain `String` constants for two reasons:
///   1. `LocalizedStringKey` is non-Sendable, so static lets fail strict
///      concurrency. `String` is `Sendable`.
///   2. SwiftUI's `View.accessibilityLabel(_:)` has a `StringProtocol`
///      overload that accepts these directly. Localisation still happens
///      via `Localizable.strings` lookup on the string literal.
public enum A11yLabel {
    // MARK: - Reader chrome
    public static let readerNextPage:        String = "Next page"
    public static let readerPreviousPage:    String = "Previous page"
    public static let readerOpenTOC:         String = "Table of contents"
    public static let readerOpenTheme:       String = "Reader theme"
    public static let readerOpenTypography:  String = "Typography settings"
    public static let readerOpenVoice:       String = "Start voice chat"
    public static let readerToggleBookmark:  String = "Bookmark this page"
    public static let readerOpenBookmarks:   String = "Bookmarks"
    public static let readerSearch:          String = "Search in book"
    public static let readerReadAloud:       String = "Read aloud"
    public static let readerStopReadAloud:   String = "Stop reading"
    public static let readerHighlightColor:  String = "Highlight color"
    public static let readerAddNote:         String = "Add note"
    public static let readerDeleteHighlight: String = "Delete highlight"
    public static let readerClose:           String = "Close reader"

    // MARK: - Chat
    public static let chatSendMessage:       String = "Send message"
    public static let chatCancelStreaming:   String = "Cancel streaming response"
    public static let chatStartVoice:        String = "Start voice chat"
    public static let chatEndVoice:          String = "End voice chat"
    public static let chatMessageInput:      String = "Message input field"
    public static let conversationRowOpen:   String = "Open conversation"
    public static let conversationDelete:    String = "Delete conversation"

    // MARK: - Library
    public static let libraryImportBook:     String = "Import book"
    public static let librarySearch:         String = "Search library"
    public static let libraryDeleteBook:     String = "Delete book"
}
