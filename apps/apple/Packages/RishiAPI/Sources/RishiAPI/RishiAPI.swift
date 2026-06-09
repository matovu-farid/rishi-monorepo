import Foundation

/// Public surface for the RishiAPI package. Plans 02-04 (`WorkerClient` actor)
/// and 02-05 (typed endpoint clients) extend this with concrete networking
/// behavior. Phase 2 ships zero third-party deps: URLSession only, per
/// .planning/research/STACK.md.
public enum RishiAPI {

    /// Marker for the public RishiAPI API version. Bump when the surface breaks.
    public static let apiVersion = "0.1.0-scaffold"
}
