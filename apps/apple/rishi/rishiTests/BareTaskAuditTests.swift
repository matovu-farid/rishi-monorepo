//
//  BareTaskAuditTests.swift
//  rishiTests
//
//  Phase 19 Plan 19-04 — F-P0-06 (app-target slice).
//
//  Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, every unannotated
//  `Task { ... }` body inherits MainActor isolation. This audit asserts
//  that every `Task {` site in the rishi/ app target carries an inline
//  `// KEEP:` or `// DETACHED:` rationale comment within the 3 source
//  lines preceding the `Task {` token — and that every `Task.detached(`
//  carries an explicit `priority:` argument.
//
//  Failure: a NEW bare Task site landed without a KEEP/DETACHED comment,
//  OR a detached site was added without explicit priority. Annotate.
//

import Foundation
import Testing

@Suite
struct BareTaskAuditTests {

    /// Resolves the repo root by walking up from this test file. The
    /// Xcode build copies the source files into a derived path, but
    /// `#filePath` still points at the live source tree on disk.
    private static func appTargetRoot() -> URL {
        // #filePath -> .../apps/apple/rishi/rishiTests/BareTaskAuditTests.swift
        let here = URL(fileURLWithPath: #filePath)
        // .deletingLastPathComponent() -> .../rishiTests
        // .deletingLastPathComponent() -> .../rishi
        // appending("rishi") -> .../rishi/rishi   (the app target source dir)
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi")
    }

    /// Recursively walks the app-target source tree and returns absolute
    /// paths to every `*.swift` file.
    private static func swiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    // MARK: - Test 1 — every bare `Task {` carries a KEEP/DETACHED comment

    @Test
    func test_allTaskSitesAnnotated() throws {
        let root = Self.appTargetRoot()
        let files = Self.swiftFiles(under: root)
        #expect(!files.isEmpty, "no Swift files found under \(root.path)")

        var unannotated: [String] = []

        for file in files {
            // Skip the audit test file itself — its body discusses `Task {`
            // textually but does not spawn tasks.
            if file.lastPathComponent == "BareTaskAuditTests.swift" { continue }

            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")

            for (idx, line) in lines.enumerated() {
                // Match a bare `Task {` (the literal). We deliberately
                // tolerate `Task { @MainActor in` and `Task { [weak self]`
                // — those are still bare Tasks (no .detached) and still
                // require a KEEP comment under default-isolation = MainActor.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isTaskOpen =
                    trimmed.hasPrefix("Task {") ||
                    trimmed.contains(" Task {") ||
                    trimmed.contains("= Task {") ||
                    trimmed.contains("(Task {")
                guard isTaskOpen else { continue }
                // Exclude `Task.detached(` — handled by test 2.
                if trimmed.contains("Task.detached(") { continue }
                // Exclude `Task<` generic declarations (e.g. `var t: Task<Void,Never>?`).
                if trimmed.contains("Task<") { continue }

                // Look back up to 3 source lines for KEEP / DETACHED marker.
                let lookbackStart = max(0, idx - 3)
                let window = lines[lookbackStart..<idx].joined(separator: "\n")
                let hasMarker =
                    window.contains("// KEEP:") ||
                    window.contains("// DETACHED:")
                if !hasMarker {
                    let rel = file.path.replacingOccurrences(
                        of: root.deletingLastPathComponent().path + "/",
                        with: ""
                    )
                    unannotated.append("\(rel):\(idx + 1) — \(trimmed)")
                }
            }
        }

        #expect(unannotated.isEmpty, """
            \(unannotated.count) bare Task site(s) lack a KEEP/DETACHED comment.
            Add `// KEEP: <reason>` or `// DETACHED: <reason>` on the line above:
            \(unannotated.joined(separator: "\n"))
            """)
    }

    // MARK: - Test 2 — every `Task.detached(` carries an explicit priority

    @Test
    func test_detachedSitesUseExplicitPriority() throws {
        let root = Self.appTargetRoot()
        let files = Self.swiftFiles(under: root)

        var missingPriority: [String] = []

        for file in files {
            if file.lastPathComponent == "BareTaskAuditTests.swift" { continue }

            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")

            for (idx, line) in lines.enumerated() {
                guard line.contains("Task.detached(") else { continue }
                // Detached sites must explicitly name their priority. Either
                // the keyword appears on the same line OR within the next 2
                // lines (multi-line call ergonomics).
                let lookahead = lines[idx..<min(lines.count, idx + 3)].joined(separator: "\n")
                if !lookahead.contains("priority:") {
                    let rel = file.path.replacingOccurrences(
                        of: root.deletingLastPathComponent().path + "/",
                        with: ""
                    )
                    missingPriority.append("\(rel):\(idx + 1) — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(missingPriority.isEmpty, """
            \(missingPriority.count) Task.detached site(s) lack an explicit `priority:` argument:
            \(missingPriority.joined(separator: "\n"))
            """)
    }
}
