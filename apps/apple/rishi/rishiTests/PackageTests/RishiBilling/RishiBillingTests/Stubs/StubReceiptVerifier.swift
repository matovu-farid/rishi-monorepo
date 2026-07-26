@testable import rishi
import Foundation
import os
import Testing


// Wave 0 (plan 13-01) defined `ReceiptVerifier` + `VerifyReceiptResponse`
// locally in this file. Wave 1 plan 13-03 promoted both into the production
// `RishiBilling` module; this file now re-imports the public protocol and
// only declares the test stub class. Wave 0 call sites that pass
// `Result<VerifyReceiptResponse, Error>` to the constructor continue to
// compile unchanged because the promoted `VerifyReceiptResponse` has the
// same field shape and Equatable / Decodable conformances.

public final class StubReceiptVerifier: ReceiptVerifier, @unchecked Sendable {

    public struct Call: Equatable, Sendable {
        public let jws: String
        public let productId: String
        public let transactionId: UInt64
    }

    // OSAllocatedUnfairLock with scoped withLock is async-safe under Swift 6
    // strict. NSLock.unlock() is unavailable from async contexts; same
    // workaround as Phase 03 KeychainBackend.
    private let _calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
    private let result: Result<VerifyReceiptResponse, Error>

    public var calls: [Call] { _calls.withLock { $0 } }

    public init(result: Result<VerifyReceiptResponse, Error> = .success(
        .init(verified: true, premiumUntil: .distantFuture, reason: nil)
    )) {
        self.result = result
    }

    public func verify(jws: String, productId: String, transactionId: UInt64)
        async throws -> VerifyReceiptResponse {
        _calls.withLock {
            $0.append(.init(jws: jws, productId: productId, transactionId: transactionId))
        }
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}
