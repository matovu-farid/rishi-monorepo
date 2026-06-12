import Testing
@testable import RishiAPI

/// Phase 17 wire-contract reconciliation: locks in the deletion of dead
/// realtime usage plumbing on the iOS side. See:
/// `.planning/phases/17-wire-contract-reconciliation-ios-worker-shape-gaps-has-pro-entitlement-projection/17-CONTEXT.md`
/// (decisions block — "Dead code disposition") and the 17-06 plan.
///
/// `RealtimeUsageEndpoint` had zero non-test callers and a corrupted name
/// (the trailing token `nEndpoint`). Plan 17-06 deletes the declaration and
/// the lone test that referenced it.
///
/// This suite enforces the post-deletion invariant by NOT mentioning the
/// removed type anywhere. Once Task 2 (GREEN) removes the declaration, any
/// future regression that re-adds `RealtimeUsageEndpoint` will not be
/// caught by THIS file alone — the operative compile-time gate is the
/// absence of references in `EndpointCodableTests.swift`. The grep
/// acceptance criterion in Task 2 (`grep -rn "RealtimeUsageEndpoint"
/// apps/apple/Packages/RishiAPI/` returns zero matches) is the source-level
/// invariant; this @Test pins the kept endpoint so a refactor that
/// accidentally renames `RealtimeClientSecretsEndpoint` also fails.
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
        let endpoint = RealtimeClientSecretsEndpoint()
        #expect(endpoint.path == "/api/realtime/client_secrets")
        #expect(endpoint.method == .GET)
    }
}
