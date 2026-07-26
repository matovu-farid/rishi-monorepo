@testable import rishi
#if canImport(CoreML)
import Foundation
import Testing
import CoreML


/// Production embedder behavioural tests. The vendored Core ML model
/// (`AllMiniLML6V2.mlmodel`) is loaded from `PackageTestResourceBundle.bundle` and the
/// embedder is exercised end-to-end:
///
///   - construct via the 0-arg `init()` (resolves model + vocab in-bundle).
///   - `embed(_:)` returns exactly 384 floats.
///   - the model's baked-in pooling + L2 normalization gives a unit vector.
///   - same input -> same output across two calls (deterministic).
///   - different inputs produce visibly different vectors (>= 10 coords).
///
/// Core ML compiles the `.mlmodel` to `.mlmodelc` at first load (~500 ms
/// cold-start on dev host); subsequent inferences are sub-100 ms. The
/// embedder is `@unchecked Sendable` and guards its lazy MLModel reference
/// behind an `OSAllocatedUnfairLock<MLModel?>` so callers can share one
/// instance from the eventual VoiceSession actor.
@Suite("CoreMLMiniLMEmbedder")
struct CoreMLMiniLMEmbedderTests {
    @Test func constructsFromBundleResources() throws {
        _ = try CoreMLMiniLMEmbedder()
    }

    @Test func embedReturns384Dim() async throws {
        let embedder = try CoreMLMiniLMEmbedder()
        let vec = try await embedder.embed("hello world")
        #expect(vec.count == 384)
    }

    @Test func outputIsL2Normalized() async throws {
        let embedder = try CoreMLMiniLMEmbedder()
        let vec = try await embedder.embed("the quick brown fox")
        let sumSq = vec.reduce(Float32(0)) { $0 + $1 * $1 }
        // The model bakes in L2 normalization, so the output vector should
        // already be unit length up to inference rounding.
        #expect(abs(sumSq - 1.0) < 1e-3, "L2 norm = \(sumSq)")
    }

    @Test func sameInputIsDeterministic() async throws {
        let embedder = try CoreMLMiniLMEmbedder()
        let a = try await embedder.embed("hello world")
        let b = try await embedder.embed("hello world")
        #expect(a.count == b.count)
        var maxDelta: Float32 = 0
        for i in 0..<a.count {
            maxDelta = max(maxDelta, abs(a[i] - b[i]))
        }
        #expect(maxDelta < 1e-5, "max coordinate delta = \(maxDelta)")
    }

    @Test func differentInputsDifferOnManyCoordinates() async throws {
        let embedder = try CoreMLMiniLMEmbedder()
        let hello = try await embedder.embed("hello")
        let goodbye = try await embedder.embed("goodbye")
        var differingCoords = 0
        for i in 0..<hello.count {
            if abs(hello[i] - goodbye[i]) > 1e-3 {
                differingCoords += 1
            }
        }
        #expect(differingCoords >= 10,
                "only \(differingCoords) coordinates differ — model may be returning a constant vector")
    }

    @Test func prewarmIsIdempotent() async throws {
        let embedder = try CoreMLMiniLMEmbedder()
        await embedder.prewarm()
        await embedder.prewarm()
        // No assertion — verifying it doesn't crash or throw.
    }
}
#endif
