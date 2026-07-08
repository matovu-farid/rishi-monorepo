import Testing
import Foundation
@testable import RishiVoice
import RishiCore
import RishiAudio
import RealtimeAPI

@Suite("RishiVoice package smoke")
struct PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiVoice.version == "0.1.0-scaffold")
    }

    @Test("Pinned SHA constant matches Spike B verdict")
    func pinnedSHAMatchesSpikeB() {
        #expect(RishiVoice.realtimeOpenAIPinnedSHA ==
                "46f393d9e2e60724aadc30062f75ee73bbcdb8fc")
    }

    @Test("RishiCore Message is reachable from the test target")
    func rishiCoreMessageIsReachable() {
        let convId = UUID()
        let msg = Message(
            conversationId: convId,
            role: .assistant,
            content: "smoke"
        )
        #expect(msg.role == .assistant)
        #expect(msg.content == "smoke")
    }

    @Test("RishiAudio ActiveMode.voice is reachable")
    func rishiAudioActiveModeVoiceIsReachable() {
        #expect(ActiveMode.voice.rawValue == "voice")
    }

    @Test("RealtimeAPI product is linked (Session type reachable)")
    func realtimeAPIIsLinked() {
        // Type-only reachability proof; we never instantiate Session here.
        // swift-realtime-openai's `RealtimeAPI` library re-exports the `Core`,
        // `UI`, and `WebRTC` submodules (see RealtimeAPI.swift: `@_exported
        // import Core` etc.). We probe `Session` (from `Core`) because the
        // user-facing `Conversation` type collides with `RishiCore.Conversation`
        // and would force ambiguity. `Session` has no such collision and is a
        // public top-level type from `Core` that proves the dep chain links.
        let typeName = String(describing: Core.Session.self)
        #expect(typeName.contains("Session"))
    }

    @Test("VOICE-08: package contains no CallKit references")
    func noCallKitImports() throws {
        // Walk Sources/RishiVoice/**/*.swift and assert zero occurrences of
        // `import CallKit` or `CallKit.`. Smoke test enforces the VOICE-08
        // ground rule at CI time — iOS 18.4.1 CallKit regression bans it.
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RishiVoiceTests/
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // RishiVoice/
            .appendingPathComponent("Sources/RishiVoice", isDirectory: true)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: nil
        ) else {
            Issue.record("Could not enumerate \(sourcesDir.path)")
            return
        }

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Walk lines and strip comments before scanning — RishiVoice.swift's
            // own doc comments necessarily mention "CallKit" in prose to
            // document the VOICE-08 ban. We only want to catch real code:
            // `import CallKit` (any line) or `CallKit.` outside comments.
            var hit = false
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                // Drop full-line comments and trim trailing `//...` from code lines.
                let trimmed = line.drop(while: { $0.isWhitespace })
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                let codePortion: String = {
                    if let range = line.range(of: "//") {
                        return String(line[..<range.lowerBound])
                    }
                    return line
                }()
                if codePortion.contains("import CallKit") ||
                   codePortion.contains("CallKit.") {
                    hit = true
                    break
                }
            }
            if hit {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "VOICE-08: CallKit forbidden — found in: \(offenders)")
    }
}
