import Foundation
@testable import RishiVoice
import RishiCore

/// Minimal `EphemeralKeyFetching` stub used by reconnect / preemption tests.
final class StubEphemeralKeyFetcher: EphemeralKeyFetching, @unchecked Sendable {
    private let result: Result<EphemeralKey, Error>

    init(result: Result<EphemeralKey, Error>) {
        self.result = result
    }

    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        try result.get()
    }
}
