@testable import rishi
import Foundation

enum PackageTestResourceBundle {
    static let bundle = Bundle(for: PackageTestBundleToken.self)

    /// Resolve package fixtures from the source tree when the app's integrated
    /// Xcode test target does not copy SwiftPM package resources into the test
    /// bundle. `#filePath` remains rooted in the checkout in that environment.
    static func url(
        forResource name: String,
        withExtension ext: String,
        subdirectory: String,
        relativeTo sourceFilePath: String
    ) -> URL? {
        var directory = URL(fileURLWithPath: sourceFilePath)
            .deletingLastPathComponent()

        while directory.path != directory.deletingLastPathComponent().path {
            let candidate = directory
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }

        var projectRoot = URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent()
        while projectRoot.path != projectRoot.deletingLastPathComponent().path {
            if FileManager.default.fileExists(
                atPath: projectRoot.appendingPathComponent("rishi.xcodeproj", isDirectory: true).path
            ) {
                let moduleRoots = [
                    projectRoot.appendingPathComponent("rishi/Modules/RishiReader/RishiReader", isDirectory: true),
                    projectRoot.appendingPathComponent("rishi/Modules/RishiAudio/RishiAudio", isDirectory: true),
                    projectRoot.appendingPathComponent("rishi/Modules/RishiAPI/RishiAPI", isDirectory: true)
                ]
                for moduleRoot in moduleRoots {
                    let candidate = moduleRoot
                        .appendingPathComponent(subdirectory, isDirectory: true)
                        .appendingPathComponent("\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
                break
            }
            projectRoot = projectRoot.deletingLastPathComponent()
        }

        return bundle.url(
            forResource: name,
            withExtension: ext,
            subdirectory: subdirectory
        )
    }
}

private final class PackageTestBundleToken {}
