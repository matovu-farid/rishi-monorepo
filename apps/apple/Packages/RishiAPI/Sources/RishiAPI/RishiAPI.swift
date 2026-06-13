import Foundation

/// Public surface for the RishiAPI package. Plan 02-04 ships the `WorkerClient`
/// actor + `TokenProvider` / `ErrorEnvelope` plumbing. Plan 02-05 layers typed
/// endpoint clients on top. Phase 2 ships zero third-party deps: URLSession
/// only, per .planning/research/STACK.md.
enum RishiAPI {

    /// Marker for the public RishiAPI API version. Bump when the surface breaks.
    static let apiVersion = "0.3.0-worker-client"
}
