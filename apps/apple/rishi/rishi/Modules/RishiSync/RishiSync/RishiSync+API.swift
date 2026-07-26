// RishiSync — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiSync exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiSync is the bidirectional sync engine. Outbound: detect
// dirty local rows and push them to the Worker. Inbound: pull
// changes since a cursor and apply them to local stores. Wake-up
// happens via BGTaskScheduler and silent APNs pushes.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 5 unused exports).

// MARK: - Engine
//
// SyncEngine                  — `Engine/SyncEngine.swift`. Actor. The orchestrator that
//                                runs one push+pull cycle. Triggered by the queue, push
//                                notifications, or background tasks.
// SyncQueue                   — `Engine/SyncQueue.swift`. Actor. The dirty-row queue
//                                consumed by SyncEngine.
// SyncQueueItem               — `Engine/SyncQueue.swift`. A single dirty item (kind + id).
// SyncStatus                  — `Engine/SyncStatus.swift`. Observable status holder for
//                                Settings UI (lastSyncedAt, pending count, last error).
// PositionDebouncer           — `Engine/PositionDebouncer.swift`. Actor. Coalesces rapid
//                                position updates into one Worker call.
// ChatSyncRefreshDelegate     — `Engine/ChatSyncRefreshDelegate.swift`. Lets RishiSync tell
//                                the chat layer to refresh its in-memory state after a pull.

// MARK: - Outbound (uploaders)
//
// BookUploader                — `Outbound/BookUploader.swift`. Pushes Book rows + cover assets.
// ConversationUploader        — `Outbound/ConversationUploader.swift`. Pushes Conversation rows.
// HighlightUploader           — `Outbound/HighlightUploader.swift`. Pushes Highlight rows.
// MessageUploader             — `Outbound/MessageUploader.swift`. Pushes Message rows.
// PositionUploader            — `Outbound/PositionUploader.swift`. Pushes Position rows
//                                (debounced).

// MARK: - Inbound (fetchers + applier)
//
// RemoteChangeFetcher         — `Inbound/RemoteChangeFetcher.swift`. Pulls the generic
//                                /sync/changes feed.
// MessagesFetcher             — `Inbound/MessagesFetcher.swift`. Pulls /sync/messages since cursor.
// ConversationsFetcher        — `Inbound/ConversationsFetcher.swift`. Pulls /sync/conversations
//                                since cursor.
// ChangeApplier               — `Inbound/ChangeApplier.swift`. Writes pulled changes back into
//                                BookStore / ConversationStore / etc.

// MARK: - Storage
//
// SwiftDataSyncMetadataStore  — `Storage/SwiftDataSyncMetadataStore.swift`. SyncMetadataStore
//                                over SwiftData. Persists per-kind cursors and dirty bits.
// SyncMetadataStoreBootstrap  — `Storage/SwiftDataSyncMetadataStore.swift`. Helper for creating
//                                an in-memory SwiftData container/store in tests and previews.

// MARK: - Background / Wake-up
//
// BackgroundTaskCoordinator   — `Background/BackgroundTaskCoordinator.swift`. Registers and
//                                handles BGTaskScheduler identifiers for periodic sync.
// APNsDeviceRegistrar         — `Background/APNsDeviceRegistrar.swift`. Actor. Registers
//                                the APNs device token with the Worker so silent pushes can
//                                wake sync.
// SilentPushHandler           — `Background/SilentPushHandler.swift`. Entry point for
//                                content-available push notifications. Calls SyncEngine.

// MARK: - Views
//
// SettingsSyncSection         — `UI/SettingsSyncSection.swift`. Settings row showing sync
//                                status + manual "Sync now" button.
// SyncStatusView              — `UI/SyncStatusView.swift`. Inline status pill (last synced /
//                                pending / failed).

// MARK: - Kept public on purpose
//
// (Types that LOOK like they could be internal but were deliberately
// kept public during the 2026-06-13 surface audit. See commit fb4f04f06.)
//
// SyncEngineConfig            — `Engine/SyncEngineConfig.swift`. Held public so the app
//                                target can construct one with custom intervals during
//                                debug builds and integration tests.
// SyncEntityKind              — `Engine/SyncEntityKind.swift`. The kind enum is referenced
//                                by SyncQueueItem (public), so it must stay public.
// SyncPendingItem             — `Storage/SyncMetadataStore.swift`. Surfaced through the
//                                SyncMetadataStore protocol; pulling it back to internal
//                                would break the protocol's public contract.
// SyncStatusSnapshot          — `Engine/SyncStatus.swift`. Sendable snapshot the UI binds
//                                to; demoting it would force the UI types internal too.
// SyncMetadataStore           — kept public so RishiTesting can supply an in-memory
//                                implementation for engine tests.
