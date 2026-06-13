// RishiCore — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiCore exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiCore is the dependency-free domain layer. It defines the
// shared models (Book, Message, etc.) and the store protocols every
// other package implements or consumes. It has no UI, no network,
// no database — just types and protocol shapes.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit).

// MARK: - Models / Types
//
// Book                        — `Models/Book.swift`. A single book in the
//                                user's library (id, title, author, format, paths, timestamps).
// BookFormat                  — `Models/Book.swift`. Enum: .epub / .pdf. The two supported reader formats.
// Conversation                — `Models/Conversation.swift`. A chat thread, optionally scoped to a book.
// Highlight                   — `Models/Highlight.swift`. A user-saved range of text inside a book.
// HighlightColor              — `Models/Highlight.swift`. Enum of highlight colors (yellow, green, blue, pink).
// Message                     — `Models/Message.swift`. A single chat message inside a conversation.
// MessageRole                 — `Models/Message.swift`. Enum: .user / .assistant / .system.
// Position                    — `Models/Position.swift`. The last-read locator for a book (serialized as JSON string).
// User                        — `Models/User.swift`. The signed-in user (id, email, displayName, hasPro).

// MARK: - Identifiers
//
// BookID, UserID, HighlightID,
// PositionID, ConversationID,
// MessageID                   — `Models/Identifiers.swift`. Strongly-named UUID typealiases used
//                                throughout the codebase so signatures read clearly.

// MARK: - Stores (protocols)
//
// BookStore                   — `Protocols/BookStore.swift`. CRUD over Book rows.
// ConversationStore           — `Protocols/ConversationStore.swift`. CRUD over Conversation rows.
// HighlightStore              — `Protocols/HighlightStore.swift`. CRUD over Highlight rows.
// MessageStore                — `Protocols/MessageStore.swift`. CRUD over Message rows.
// PositionStore               — `Protocols/PositionStore.swift`. Upsert/read the last-read Position per book.
//
// All five are implemented by RishiDB (GRDB-backed) and by RishiTesting (in-memory).

// MARK: - Services (protocols)
//
// AuthService                 — `Protocols/AuthService.swift`. Sign-in / sign-out / current-user surface.
//                                Implemented by RishiAuth.RishiAuthService and RishiTesting.FakeAuthService.
// ChatService                 — `Protocols/ChatService.swift`. Streaming-chat send/receive surface.
//                                Implemented by RishiChat.RishiChatService and RishiTesting.FakeChatService.
// ChatEvent                   — `Protocols/ChatService.swift`. Stream event enum: .delta / .done / .error.

// MARK: - Errors
//
// RishiError                  — `Errors/RishiError.swift`. The single error type returned across
//                                module boundaries (network, auth, billing, storage).

// MARK: - Kept public on purpose
//
// (Types that LOOK like they could be internal but were deliberately
// kept public during the 2026-06-13 surface audit. See commit 650a6edd8.)
//
// WorkerAPI                   — empty marker protocol kept public so RishiTesting can declare
//                                MockWorkerClient: WorkerAPI without depending on RishiAPI. Removing
//                                this would force a RishiAPI dependency in the test package.
// SubscriptionRequirement     — currently only constructed inside RishiError.subscriptionRequired,
//                                kept public because external callers pattern-match on it when
//                                rendering the paywall.
// RishiError.errorDescription — kept public so LocalizedError conformance works across modules
//                                (Swift requires LocalizedError members to match the protocol's
//                                public access).
