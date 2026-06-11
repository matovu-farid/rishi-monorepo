import Foundation
import Testing

@Suite("StubReceiptVerifier")
struct StubReceiptVerifierTests {

    private struct StubError: Error, Equatable {}

    @Test("verify records its arguments as a Call")
    func testCallCapture() async throws {
        let stub = StubReceiptVerifier()
        _ = try await stub.verify(jws: "JWS", productId: "org.fidexa.rishi.pro.monthly", transactionId: 42)
        #expect(stub.calls.count == 1)
        #expect(stub.calls.first?.jws == "JWS")
        #expect(stub.calls.first?.productId == "org.fidexa.rishi.pro.monthly")
        #expect(stub.calls.first?.transactionId == 42)
    }

    @Test("failure result propagates as a thrown error")
    func testResultPropagation() async {
        let stub = StubReceiptVerifier(result: .failure(StubError()))
        await #expect(throws: StubError.self) {
            _ = try await stub.verify(jws: "x", productId: "y", transactionId: 1)
        }
    }

    @Test("default init returns verified=true, premiumUntil=distantFuture, reason=nil")
    func testDefaultResultIsVerifiedTrue() async throws {
        let stub = StubReceiptVerifier()
        let res = try await stub.verify(jws: "x", productId: "y", transactionId: 1)
        #expect(res.verified == true)
        #expect(res.premiumUntil == .distantFuture)
        #expect(res.reason == nil)
    }
}
