import Foundation
import RishiAPI
import RishiLogging

/// Production ``ReceiptVerifier`` wrapping ``WorkerClient``.
///
/// Posts `(jws, productId, transactionId)` to `POST /api/billing/verify-receipt`
/// (see ``VerifyReceiptEndpoint``) and decodes the worker's canonical
/// premium status. Transport errors surface as
/// ``VerifyReceiptError/network`` so the caller can distinguish "worker
/// unreachable" (leave-unfinished) from "worker actively rejected"
/// (finish-and-don't-grant).
public actor WorkerReceiptVerifier: ReceiptVerifier {

    private let client: WorkerClient

    public init(client: WorkerClient) {
        self.client = client
    }

    public func verify(jws: String, productId: String, transactionId: UInt64)
        async throws -> VerifyReceiptResponse {
        let endpoint = VerifyReceiptEndpoint(
            body: VerifyReceiptEndpoint.Request(
                jws: jws,
                productId: productId,
                transactionId: transactionId
            )
        )
        do {
            let resp = try await client.send(endpoint)
            return VerifyReceiptResponse(
                verified: resp.verified,
                premiumUntil: resp.premiumUntil,
                reason: resp.reason
            )
        } catch {
            Log.event("iap.worker.verify_failed", level: .warning,
                      data: ["error": String(describing: error)])
            throw VerifyReceiptError.network(String(describing: error))
        }
    }
}
