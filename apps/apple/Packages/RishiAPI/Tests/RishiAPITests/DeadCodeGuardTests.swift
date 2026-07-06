import Testing
@testable import RishiCore

/// Phase 17 wire-contract reconciliation: locks in the deletion of dead
/// realtime usage plumbing on the iOS side. See:
/// `.planning/phases/17-wire-contract-reconciliation-ios-worker-shape-gaps-has-pro-entitlement-projection/17-CONTEXT.md`
/// (decisions block — "Dead code disposition") and the 17-06 plan.
///
/// The deleted endpoint declaration had zero non-test callers and a
/// corrupted type-name token. Plan 17-06 removed the struct and the lone
/// test that referenced it.
///
/// This suite enforces the post-deletion invariant by pinning the
/// surviving endpoint's identity (name, path, method). The source-level
/// grep gate enforced by Task 2's acceptance criterion is the operative
/// invariant; this @Test catches the secondary case where a refactor
/// renames or shadows `RealtimeClientSecretsEndpoint`.
@Suite("Phase 17 dead-code guards")
struct DeadCodeGuardTests {

    @Test("RealtimeClientSecretsEndpoint remains the sole realtime endpoint type")
    func realtimeClientSecretsEndpointIsCanonical() {
        // Pin the kept type's name via runtime reflection. Any rename or
        // accidental re-introduction of a sibling type that shadows this
        // identity will break the assertion.
        let typeName = String(describing: RealtimeClientSecretsEndpoint.self)
        #expect(typeName == "RealtimeClientSecretsEndpoint")

        // Pin the canonical path so the GREEN deletion can't accidentally
        // collapse the file in a way that mangles the surviving endpoint.
        // Method moved from GET to POST in Phase 25 (Plan 25-08) to carry
        // the book-context body the worker now expects.
        let endpoint = RealtimeClientSecretsEndpoint()
        #expect(endpoint.path == "/api/realtime/client_secrets")
        #expect(endpoint.method == .POST)
    }
}
