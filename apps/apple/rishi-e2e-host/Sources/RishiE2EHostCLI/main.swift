import Foundation
import RishiE2EHost

@main
struct RishiE2EHostCLI {
    static func main() async throws {
        let lines = try await SharedReadingCLI.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: ProcessInfo.processInfo.environment
        )
        lines.forEach { print($0) }
    }
}
