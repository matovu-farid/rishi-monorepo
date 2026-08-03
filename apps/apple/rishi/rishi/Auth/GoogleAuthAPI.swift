import Foundation

/// `POST /auth/google` — exchange a Google ID token for the existing Rishi
/// access/refresh token pair and UUID-backed user response.
struct GoogleAuthEndpoint: WorkerEndpointWithBody {
    typealias Response = JWTEndPoint.ResponseType

    struct Body: Encodable, Sendable, Equatable {
        let identityToken: String

        init(identityToken: String) {
            self.identityToken = identityToken
        }
    }

    let method: HTTPMethod = .POST
    let path = "/auth/google"
    let body: Body

    init(body: Body) {
        self.body = body
    }
}
