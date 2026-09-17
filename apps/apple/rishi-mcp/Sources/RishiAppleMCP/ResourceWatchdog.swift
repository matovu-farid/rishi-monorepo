import Foundation

enum ResourceWatchdog {
    static func run(
        interval: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        check: @escaping @Sendable () async throws -> Void,
        onPressure: @escaping @Sendable (any Error) async -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await sleep(interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try await check()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await onPressure(error)
                return
            }
        }
    }
}
