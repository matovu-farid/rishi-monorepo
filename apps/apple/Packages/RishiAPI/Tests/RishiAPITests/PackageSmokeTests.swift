import Foundation
import Testing
@testable import RishiAPI

@Suite("RishiAPI package smoke")
struct PackageSmokeTests {

    @Test func apiVersionIsScaffoldMarker() {
        #expect(RishiAPI.apiVersion == "0.1.0-scaffold")
    }

    @Test func httpMethodCoversCommonVerbs() {
        let methods = Set(HTTPMethod.allCases.map(\.rawValue))
        #expect(methods.isSuperset(of: ["GET", "POST", "PUT", "DELETE", "PATCH"]))
    }

    @Test func workerEndpointProtocolIsUsable() {
        // A concrete fixture endpoint must compile against the protocol —
        // this is what plan 02-05 will scale up to every worker route.
        struct PingResponse: Decodable, Sendable { let ok: Bool }
        struct PingEndpoint: WorkerEndpoint {
            typealias Response = PingResponse
            let method: HTTPMethod = .GET
            let path: String = "/ping"
        }
        let e = PingEndpoint()
        #expect(e.method == .GET)
        #expect(e.path == "/ping")
    }
}
