// RishiDB — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiDB exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiDB is the GRDB-backed persistence layer. It opens the
// SQLite database (DatabaseQueue or DatabasePool), defines the
// schema, and provides GRDB-backed implementations of every store
// protocol defined in RishiCore.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 51 unused exports).

// MARK: - Database bootstrap
//
// RishiDB                     — `RishiDB.swift`. Namespace enum. Holds the two factory
//                                functions that open a database file with migrations applied.
// RishiDB.makeDatabaseQueue   — `RishiDB.swift`. Opens a GRDB DatabaseQueue at the given URL
//                                (single writer/reader, simpler). Used by tests and small flows.
// RishiDB.makeDatabasePool    — `RishiDB.swift`. Opens a GRDB DatabasePool at the given URL
//                                (concurrent reads while one writer). The app uses this in prod.

// MARK: - Stores (GRDB implementations of RishiCore protocols)
//
// GRDBBookStore               — `Stores/GRDBBookStore.swift`. BookStore over GRDB.
// GRDBConversationStore       — `Stores/GRDBConversationStore.swift`. ConversationStore over GRDB.
// GRDBHighlightStore          — `Stores/GRDBHighlightStore.swift`. HighlightStore over GRDB.
// GRDBMessageStore            — `Stores/GRDBMessageStore.swift`. MessageStore over GRDB.
// GRDBPositionStore           — `Stores/GRDBPositionStore.swift`. PositionStore over GRDB.
//
// All five take an `any DatabaseWriter` at init so callers can pass
// either a DatabaseQueue or a DatabasePool. Each is `@unchecked
// Sendable` because GRDB writers are themselves thread-safe.

// MARK: - Schema
//
// Tables                      — `Schema/Tables.swift`. Namespace enum holding the column
//                                names and table names referenced by both the stores and
//                                the migrations. String constants, not GRDB Record types.
// Tables.SyncMetadata         — `Schema/Tables.swift`. Nested namespace for the
//                                sync-metadata table (used by RishiSync).
