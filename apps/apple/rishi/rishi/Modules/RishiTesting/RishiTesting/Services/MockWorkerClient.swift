import Foundation


/// Stub conforming to `RishiCore.WorkerAPI`. Phase 2 (`RishiAPI`) will extend
/// `WorkerAPI` with the real method surface and this mock will gain configurable
/// canned responses. Today it exists so feature-package tests can declare a
/// `WorkerAPI` dependency and inject a placeholder.
public final class MockWorkerClient: WorkerAPI, @unchecked Sendable {
    public init() {}
}
