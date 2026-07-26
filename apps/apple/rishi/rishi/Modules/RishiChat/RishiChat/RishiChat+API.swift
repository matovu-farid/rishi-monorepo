// RishiChat — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiChat exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiChat is the in-app AI chat surface: conversations list,
// chat panel, streaming state. The transport is a ChatService
// (RishiCore protocol) — this package supplies a WorkerClient-backed
// implementation.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 8 unused exports).

// MARK: - Views
//
// ChatPanelView               — `UI/ChatPanelView.swift`. The chat panel UI (message list +
//                                composer). Used both inline next to the reader and full-screen.
// ConversationsListView       — `UI/ConversationsListView.swift`. List of past conversations
//                                with swipe-to-delete and per-row title editing.

// MARK: - View models
//
// ChatPanelViewModel          — `UI/ChatPanelViewModel.swift`. State + actions for
//                                ChatPanelView (load history, send, cancel, retry).
// ConversationsListViewModel  — `UI/ConversationsListViewModel.swift`. State + actions for
//                                ConversationsListView (load list, rename, delete).

// MARK: - Services
//
// RishiChatService            — `Service/ChatService.swift`. Actor. Implements
//                                RishiCore.ChatService over WorkerClient streaming. The app
//                                injects this as the active ChatService.
// ConversationLookup          — `Storage/ConversationLookup.swift`. Actor. Finds-or-creates
//                                the active Conversation for a given (user, book) pair.

// MARK: - Protocols
//
// ChatDirtyHook               — `Service/ChatDirtyHook.swift`. Called by the chat service to
//                                signal that local chat state has changed and the sync engine
//                                should look at it.

// MARK: - Kept public on purpose
//
// (Types that LOOK like they could be internal but were deliberately
// kept public during the 2026-06-13 surface audit. See commit d301cf5e1.)
//
// ChatStreamingState          — kept public because ChatPanelView observes it directly via
//                                @Bindable; collapsing it into ChatPanelViewModel would
//                                require an internal-to-public refactor of the view layer.
