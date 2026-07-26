@testable import rishi
import Foundation
import Testing


/// ReceiptVerifier contract — Plan 13-03 IAP-10.
///
/// Plan 13-01 introduced the protocol locally in the test target's Stubs/
/// directory. Plan 13-03 promotes ReceiptVerifier + VerifyReceiptResponse +
/// VerifyReceiptError into the production module. These tests guard the
/// promoted contract so any future divergence (renamed method, dropped
/// associated value, lost Sendable conformance) fails fast.
@Suite("ReceiptVerifier contract")
struct ReceiptVerifierContractTests {

    @Test("Stub conforms to the promoted protocol")
    func testStub_conformsToProtocol() {
        let v: any ReceiptVerifier = StubReceiptVerifier()
        _ = v
    }

    @Test("Stub records each verify() call's arguments")
    func testStub_capturesArguments() async throws {
        let stub = StubReceiptVerifier()
        _ = try await stub.verify(jws: "abc", productId: "org.fidexa.rishi.pro.monthly", transactionId: 7)
        #expect(stub.calls.count == 1)
        #expect(stub.calls[0].jws == "abc")
        #expect(stub.calls[0].productId == "org.fidexa.rishi.pro.monthly")
        #expect(stub.calls[0].transactionId == 7)
    }

    @Test("Stub returns the configured response value")
    func testStub_returnsConfiguredResponse() async throws {
        let until = Date(timeIntervalSince1970: 2_000_000_000)
        let stub = StubReceiptVerifier(result: .success(
            .init(verified: true, premiumUntil: until, reason: nil)
        ))
        let response = try await stub.verify(jws: "j", productId: "p", transactionId: 1)
        #expect(response.verified == true)
        #expect(response.premiumUntil == until)
        #expect(response.reason == nil)
    }

    @Test("Stub throws the configured error")
    func testStub_throwsWhenConfigured() async {
        struct StubFailure: Error, Equatable {}
        let stub = StubReceiptVerifier(result: .failure(StubFailure()))
        await #expect(throws: StubFailure.self) {
            _ = try await stub.verify(jws: "j", productId: "p", transactionId: 1)
        }
    }

    @Test("VerifyReceiptResponse equality is field-wise")
    func testResponse_equatableFieldwise() {
        let date = Date(timeIntervalSince1970: 1)
        let a = VerifyReceiptResponse(verified: true, premiumUntil: date, reason: nil)
        let b = VerifyReceiptResponse(verified: true, premiumUntil: date, reason: nil)
        let c = VerifyReceiptResponse(verified: false, premiumUntil: date, reason: "x")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("VerifyReceiptError preserves reason payload")
    func testVerifyReceiptError_associatedValues() {
        let a = VerifyReceiptError.network("offline")
        let b = VerifyReceiptError.rejected("replay_detected")
        #expect(a == .network("offline"))
        #expect(a != b)
    }
}
