// RishiTesting — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiTesting exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiTesting is a cross-module test-support library. Unlike the
// other packages, EVERYTHING here is intentionally public — these
// fakes, in-memory stores, and conformance suites must be callable
// from every other package's test target. The "narrow the public
// surface" guideline does NOT apply to RishiTesting; widening it
// is the point.
//
// Last verified: 2026-06-13 (no surface-audit changes — this
// package was deliberately excluded from the demotion sweep).

// MARK: - Namespace
//
// RishiTesting                — `RishiTesting.swift`. Namespace enum (currently a
//                                holder for shared helpers).
// RishiTestingError           — `RishiTesting.swift`. Error enum raised by the conformance
//                                helpers when an invariant fails.

// MARK: - In-memory stores (RishiCore protocol implementations)
//
// InMemoryBookStore           — `Stores/InMemoryBookStore.swift`. BookStore actor.
// InMemoryConversationStore   — `Stores/InMemoryConversationStore.swift`. ConversationStore actor.
// InMemoryHighlightStore      — `Stores/InMemoryHighlightStore.swift`. HighlightStore actor.
// InMemoryMessageStore        — `Stores/InMemoryMessageStore.swift`. MessageStore actor.
// InMemoryPositionStore       — `Stores/InMemoryPositionStore.swift`. PositionStore actor.

// MARK: - Services (fakes)
//
// FakeAuthService             — `Services/FakeAuthService.swift`. AuthService actor that
//                                always-signs-in a fixed test user.
// FakeChatService             — `Services/FakeChatService.swift`. ChatService that streams
//                                a scripted response.
// MockWorkerClient            — `Services/MockWorkerClient.swift`. WorkerAPI marker
//                                implementation; tests sub-type or stub per-test.

// MARK: - Conformance suites
//
// assertBookStoreConformance         — `Conformance/BookStoreConformance.swift`.
// assertConversationStoreConformance — `Conformance/ConversationStoreConformance.swift`.
// assertHighlightStoreConformance    — `Conformance/HighlightStoreConformance.swift`.
// assertMessageStoreConformance      — `Conformance/MessageStoreConformance.swift`.
// assertPositionStoreConformance     — `Conformance/PositionStoreConformance.swift`.
//
// Each one runs the standard CRUD/ordering tests against an
// arbitrary implementation of the matching protocol. Call from
// RishiDB tests (against GRDB) and RishiTesting's own tests
// (against the in-memory stores).
