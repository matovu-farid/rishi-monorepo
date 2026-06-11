import Foundation
import os
import Testing

public struct VerifyReceiptResponse: Sendable, Equatable, Decodable {
    public let verified: Bool
    public let premiumUntil: Date?
    public let reason: String?
    public init(verified: Bool, premiumUntil: Date?, reason: String?) {
        self.verified = verified
        self.premiumUntil = premiumUntil
        self.reason = reason
    }
}

public protocol ReceiptVerifier: Sendable {
    func verify(jws: String, productId: String, transactionId: UInt64)
        async throws -> VerifyReceiptResponse
}

public final class StubReceiptVerifier: ReceiptVerifier, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let jws: String
        public let productId: String
        public let transactionId: UInt64
    }
    // OSAllocatedUnfairLock with scoped withLock is async-safe under Swift 6 strict.
    // NSLock.unlock() is unavailable from async contexts; same workaround as
    // Phase 03 KeychainBackend.
    private let _calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
    private let result: Result<VerifyReceiptResponse, Error>
    public var calls: [Call] { _calls.withLock { $0 } }
    public init(result: Result<VerifyReceiptResponse, Error> = .success(
        .init(verified: true, premiumUntil: .distantFuture, reason: nil))) {
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
