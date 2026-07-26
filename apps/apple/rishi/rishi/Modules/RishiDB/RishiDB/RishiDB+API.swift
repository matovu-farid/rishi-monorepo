// RishiDB — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiDB exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiDB is the SwiftData-backed persistence layer. It opens the
// ModelContainer / store facade, defines the persistent model set, and
// provides implementations of every store protocol defined in RishiCore.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 51 unused exports).

// MARK: - Database bootstrap
//
// RishiDB                     — `RishiDB.swift`. Namespace enum. Holds the bootstrap
//                                functions for the SwiftData stack.
// RishiDB.makeModelContainer   — `RishiDB.swift`. Opens the SwiftData ModelContainer at the given URL.
// RishiDB.makeStore            — `RishiDB.swift`. Returns the shared SwiftData-backed store facade.

// MARK: - Stores (SwiftData implementations of RishiCore protocols)
//
// SwiftDataBookStore          — `Stores/SwiftDataBookStore.swift`. BookStore over SwiftData.
// SwiftDataConversationStore  — `Stores/SwiftDataConversationStore.swift`. ConversationStore over SwiftData.
// SwiftDataHighlightStore     — `Stores/SwiftDataHighlightStore.swift`. HighlightStore over SwiftData.
// SwiftDataMessageStore       — `Stores/SwiftDataMessageStore.swift`. MessageStore over SwiftData.
// SwiftDataPositionStore      — `Stores/SwiftDataPositionStore.swift`. PositionStore over SwiftData.
// Each store takes the shared `RishiDBStore` actor at init so callers can
// keep the same construction pattern while the package migrates to SwiftData.

// MARK: - Schema
//
// Tables                      — `Schema/Tables.swift`. Namespace enum holding the column
//                                names and table names referenced by both the stores and
//                                the migration. String constants, not SwiftData model types.
// Tables.SyncMetadata         — `Schema/Tables.swift`. Nested namespace for the
//                                sync-metadata table (used by RishiSync).
