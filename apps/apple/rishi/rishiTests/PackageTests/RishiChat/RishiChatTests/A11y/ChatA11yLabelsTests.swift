@testable import rishi
import Foundation
import Testing

/// File-level invariants for chat UI accessibility. Mirrors the pattern
/// from `ReaderA11yLabelsTests` — we assert source-level shape (uses
/// `A11yLabel`, no fixed font sizes, no raw `.animation(`) so regressions
/// are caught without needing to render SwiftUI views in a test harness.
@Suite("Chat a11y — file-level invariants")
struct ChatA11yLabelsTests {

    /// Resolve `Sources/RishiChat/UI` relative to this test file via
    /// `#filePath` so the directory walk works under both `swift test`
    /// and `xcodebuild test` (where CWD is the simulator sandbox).
    private static func chatUIDir() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent()   // A11y/
            .deletingLastPathComponent()   // RishiChatTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // RishiChat/ (package root)
        return packageRoot
            .appendingPathComponent("Sources/RishiChat/UI", isDirectory: true)
    }

    private static func chatSources() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: chatUIDir(), includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "swift" }
    }

    @Test("No fixed-size .font(.system(size:)) in chat UI (A11Y-02)")
    func noFixedFontSizes() throws {
        for url in try Self.chatSources() {
            let s = try String(contentsOf: url, encoding: .utf8)
            #expect(
                !s.contains(".font(.system(size:"),
                "Fixed font size in \(url.lastPathComponent) violates Dynamic Type"
            )
        }
    }

    @Test("No raw .animation( in chat UI (A11Y-03)")
    func noRawAnimation() throws {
        for url in try Self.chatSources() {
            let s = try String(contentsOf: url, encoding: .utf8)
            let lines = s.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") { continue }
                if line.contains(".animation(") && !line.contains(".rishiAnimation(") {
                    Issue.record(
                        "Raw .animation( in \(url.lastPathComponent):\(idx + 1) — use .rishiAnimation(_:reduce:)"
                    )
                }
            }
        }
    }

    @Test("ChatPanelView TextField + Send / Cancel use A11yLabel")
    func chatPanelLabels() throws {
        let url = try Self.chatSources().first { $0.lastPathComponent == "ChatPanelView.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        #expect(s.contains("A11yLabel.chatMessageInput"))
        #expect(s.contains("A11yLabel.chatSendMessage"))
        #expect(s.contains("A11yLabel.chatCancelStreaming"))
        // Stable identifiers used by Maestro / UI tests.
        #expect(s.contains("\"chat.input\""))
        #expect(s.contains("\"chat.send\""))
        #expect(s.contains("\"chat.cancel\""))
    }

    @Test("ChatMessageBubble exposes a role + content accessibility label")
    func messageBubbleLabel() throws {
        let url = try Self.chatSources().first { $0.lastPathComponent == "ChatMessageBubble.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        // The bubble should collapse into a single VO element labelled
        // with role + content rather than reading each text fragment.
        #expect(s.contains(".accessibilityElement(children: .ignore)"))
        #expect(s.contains(".accessibilityLabel("))
        #expect(s.contains("roleLabel") || s.contains("role.localized"))
    }

    @Test("ConversationRow surfaces shared open-verb label + per-row hint")
    func conversationRowLabel() throws {
        let url = try Self.chatSources().first { $0.lastPathComponent == "ConversationRow.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        #expect(s.contains("A11yLabel.conversationRowOpen"))
        #expect(s.contains(".accessibilityHint("))
    }

    @Test("ConversationsListView swipe-delete uses shared label")
    func conversationsDeleteLabel() throws {
        let url = try Self.chatSources().first { $0.lastPathComponent == "ConversationsListView.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        #expect(s.contains("A11yLabel.conversationDelete"))
    }
}
