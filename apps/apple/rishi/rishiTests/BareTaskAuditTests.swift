@testable import rishi
//
//  BareTaskAuditTests.swift
//  rishiTests
//
//  Phase 19 Plan 19-04 — F-P0-06 (app-target slice).
//
//  The original KEEP/DETACHED marker audit was written for the pre-flattening
//  app target. The app and its former internal packages now share the
//  consolidated `rishi/Modules` source tree, so that historical marker
//  contract no longer describes the current repository. Keep the actionable
//  source-level contract here: every `Task.detached(` must name a priority.
//

import Foundation
import Testing

@Suite
struct BareTaskAuditTests {

    /// Resolves the current app-target source tree from this test file.
    private static func appTargetRoot() -> URL {
        // #filePath -> .../apps/apple/rishi/rishiTests/BareTaskAuditTests.swift
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent() // rishiTests
            .deletingLastPathComponent() // rishi
            .appendingPathComponent("rishi", isDirectory: true)
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    @Test
    func test_detachedSitesUseExplicitPriority() throws {
        let root = Self.appTargetRoot()
        let files = Self.swiftFiles(under: root)
        #expect(!files.isEmpty, "no Swift files found under \(root.path)")

        var missingPriority: [String] = []

        for file in files {
            if file.lastPathComponent == "BareTaskAuditTests.swift" { continue }

            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments may quote the API in explanatory text without
                // being executable detached-task sites.
                if trimmed.hasPrefix("//") || !line.contains("Task.detached(") { continue }

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
            \(missingPriority.count) Task.detached site(s) lack an explicit `priority:` argument:
            \(missingPriority.joined(separator: "\n"))
            """)
    }
}
