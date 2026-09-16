@testable import rishi
//
//  PackagesTaskAuditTests.swift
//  RishiTestingTests
//
//  Phase 19 Plan 19-05 — F-P0-06 (Packages slice).
//
//  Companion to BareTaskAuditTests in the rishi app target. This suite walks
//  every Sources/ tree under apps/apple/Packages/ and asserts:
//
//   1. Every bare `Task {` site carries a `// KEEP:` or `// DETACHED:`
//      rationale comment within the 7 source lines preceding the token.
//   2. Every `Task.detached(` call carries an explicit `priority:` argument
//      (within the call line or the 2 lines following, for multi-line
//      ergonomics).
//
//  Default-isolation in packages is `nonisolated` (Swift 6 default for a
//  SwiftPM target without `defaultIsolation: .MainActor`), so most package
//  `Task { }` sites correctly run off-main and only need a KEEP annotation
//  documenting the intent. DETACHED sites are reserved for explicit
//  off-isolation hops where the calling context IS @MainActor.
//
//  Failure modes:
//   - A new bare Task site landed in any Packages/* source without an
//     annotation → fail with the offending file:line list.
//   - A new `Task.detached(` landed without `priority:` → fail.
//

import Foundation
import Testing

@Suite
struct PackagesTaskAuditTests {

    /// Resolves `apps/apple/Packages/` from this file's path. The Xcode build
    /// copies sources into a derived path, but `#filePath` still points at
    /// the live source tree on disk.
    private static func packagesRoot() -> URL {
        // #filePath -> .../apps/apple/Packages/RishiTesting/Tests/RishiTestingTests/PackagesTaskAuditTests.swift
        let here = URL(fileURLWithPath: #filePath)
        // .deletingLastPathComponent() -> .../RishiTestingTests
        // .deletingLastPathComponent() -> .../Tests
        // .deletingLastPathComponent() -> .../RishiTesting
        // .deletingLastPathComponent() -> .../Packages
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Returns every `<Packages>/<Package>/Sources/**/*.swift` URL. Tests/
    /// trees are excluded since the audit only covers production code; the
    /// test file itself discusses `Task { }` textually but does not spawn one
    /// that needs annotation.
    private static func packageSourceFiles(under packagesRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: packagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for pkgDir in entries {
            let sources = pkgDir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sources.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let enumerator = fm.enumerator(
                at: sources,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "swift" {
                    out.append(url)
                }
            }
        }
        return out
    }

    // MARK: - Test 1 — every bare `Task {` carries a KEEP/DETACHED comment

    @Test
    func test_allPackageTaskSitesAnnotated() throws {
        let root = Self.packagesRoot()
        let files = Self.packageSourceFiles(under: root)
        #expect(!files.isEmpty, "no Sources/*.swift files found under \(root.path)")

        var unannotated: [String] = []

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")

            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip doc-comment lines (`///`) that discuss Task syntax
                // textually but don't spawn one.
                if trimmed.hasPrefix("///") { continue }
                // Skip ordinary line comments that name `Task {` in prose.
                if trimmed.hasPrefix("//") { continue }

                let isTaskOpen =
                    trimmed.hasPrefix("Task {") ||
                    trimmed.contains(" Task {") ||
                    trimmed.contains("= Task {") ||
                    trimmed.contains("(Task {")
                guard isTaskOpen else { continue }
                if trimmed.contains("Task.detached(") { continue }
                if trimmed.contains("Task<") { continue }
                // `group.addTask {` is structured concurrency, not an
                // unstructured Task — excluded from the audit.
                if trimmed.contains("group.addTask") { continue }

                // Look back 7 source lines for a KEEP / DETACHED marker.
                let lookbackStart = max(0, idx - 7)
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
            \(unannotated.count) bare Task site(s) in apps/apple/Packages lack a KEEP/DETACHED comment.
            Add `// KEEP: <reason>` or `// DETACHED: <reason>` on the line above:
            \(unannotated.joined(separator: "\n"))
            """)
    }

    // MARK: - Test 2 — every `Task.detached(` carries an explicit priority

    @Test
    func test_detachedSitesUseExplicitPriority() throws {
        let root = Self.packagesRoot()
        let files = Self.packageSourceFiles(under: root)

        var missingPriority: [String] = []

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")

            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("///") { continue }
                if trimmed.hasPrefix("//") { continue }
                guard line.contains("Task.detached(") else { continue }

                let lookahead = lines[idx..<min(lines.count, idx + 3)].joined(separator: "\n")
                if !lookahead.contains("priority:") {
                    let rel = file.path.replacingOccurrences(
                        of: root.deletingLastPathComponent().path + "/",
                        with: ""
                    )
                    missingPriority.append("\(rel):\(idx + 1) — \(trimmed)")
                }
            }
        }

        #expect(missingPriority.isEmpty, """
            \(missingPriority.count) Task.detached site(s) in apps/apple/Packages lack an explicit `priority:` argument:
            \(missingPriority.joined(separator: "\n"))
            """)
    }
}
