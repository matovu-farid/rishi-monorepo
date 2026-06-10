//
//  AppChatDirtyHook.swift
//  rishi
//
//  Phase 9 Plan 09-06 — forwards RishiChat write events into the
//  Phase 7 SyncEngine. Lives in the app layer because RishiChat does
//  not import RishiSync (layer rule); the protocol seam is
//  `ChatDirtyHook` in RishiChat.
//

import Foundation
import RishiCore
import RishiChat
import RishiSync

/// Concrete ``ChatDirtyHook`` that asks the Phase 7 ``SyncEngine`` to mark
/// chat rows dirty (CHAT-04). One instance is held by ``AppDependencies`` for
/// the app lifetime and injected into ``RishiChatService`` at construction.
///
/// Sendable: yes — the only stored property is the `SyncEngine` actor reference.
struct AppChatDirtyHook: ChatDirtyHook {
    private let syncEngine: SyncEngine

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
    }

    func conversationDidUpdate(_ id: ConversationID) async {
        await syncEngine.markConversationDirty(id)
    }

    func messageDidUpdate(_ id: MessageID) async {
        await syncEngine.markMessageDirty(id)
    }
}
