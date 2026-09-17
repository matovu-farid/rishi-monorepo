import Foundation

public enum ResourceWatchdog {
    public static func run(
        sleep: @escaping @Sendable () async throws -> Void,
        check: @escaping @Sendable () async throws -> Void,
        onPressure: @escaping @Sendable (ResourcePreflightError) async -> Void
    ) async throws -> ResourcePreflightError {
        while true {
            try await sleep()
            do {
                try await check()
            } catch let error as ResourcePreflightError {
                await onPressure(error)
                return error
            }
        }
    }
}
