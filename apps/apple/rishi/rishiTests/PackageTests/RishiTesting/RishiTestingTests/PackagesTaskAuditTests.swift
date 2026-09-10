@testable import rishi
//
//  PackagesTaskAuditTests.swift
//  RishiTestingTests
//
//  Phase 19 Plan 19-05 — F-P0-06 (former Packages slice).
//
//  The internal Swift packages were flattened into the app under
//  `apps/apple/rishi/rishi/Modules`. Keep this audit pointed at that live
//  source tree so it continues to check the detached-task contract without
//  assuming the removed `apps/apple/Packages/*/Sources` layout.
//

import Foundation
import Testing

@Suite
struct PackagesTaskAuditTests {

    private static func modulesRoot() -> URL {
        // #filePath -> .../apps/apple/rishi/rishiTests/PackageTests/
        //              RishiTesting/RishiTestingTests/PackagesTaskAuditTests.swift
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent() // RishiTestingTests
            .deletingLastPathComponent() // RishiTesting
            .deletingLastPathComponent() // PackageTests
            .deletingLastPathComponent() // rishiTests
            .deletingLastPathComponent() // rishi app project
            .appendingPathComponent("rishi/Modules", isDirectory: true)
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
    func test_currentModuleSourceTreeExists() throws {
        let root = Self.modulesRoot()
        let files = Self.swiftFiles(under: root)
        #expect(!files.isEmpty, "no module Swift files found under \(root.path)")
    }

    @Test
    func test_detachedSitesUseExplicitPriority() throws {
        let root = Self.modulesRoot()
        let files = Self.swiftFiles(under: root)
        #expect(!files.isEmpty, "no module Swift files found under \(root.path)")

        var missingPriority: [String] = []

        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || !line.contains("Task.detached(") { continue }

                let lookahead = lines[idx..<min(lines.count, idx + 3)].joined(separator: "\n")
                if !lookahead.contains("priority:") {
                    let rel = file.path.replacingOccurrences(
                        of: root.path + "/",
                        with: ""
                    )
                    missingPriority.append("\(rel):\(idx + 1) — \(trimmed)")
                }
            }
        }

        #expect(missingPriority.isEmpty, """
            \(missingPriority.count) Task.detached site(s) in the flattened module tree lack an explicit `priority:` argument:
            \(missingPriority.joined(separator: "\n"))
            """)
    }
}
