//
//  AppVoiceDirtyAdapter.swift
//  rishi
//
//  Phase 10 Plan 10-06 — single dirty-mark forwarder that conforms to BOTH
//  `ChatDirtyHook` (RishiChat, Phase 9) AND `VoiceTranscriptDirtyHook`
//  (RishiVoice, Phase 10). Replaces the Phase-9 `AppChatDirtyHook` so the
//  `SyncEngine` sees chat + voice transcript dirty marks through a single
//  composition seam.
//
//  Layer rule: RishiChat does not depend on RishiVoice; RishiVoice does not
//  depend on RishiChat or RishiSync. The protocols mirror each other in
//  shape — this adapter just lifts both into the app target.
//

import Foundation
import RishiCore
import RishiChat
import RishiSync
import RishiVoice

/// Concrete dual adapter forwarding both `ChatDirtyHook` (Phase 9) AND
/// `VoiceTranscriptDirtyHook` (Phase 10) into the Phase-7 ``SyncEngine``.
/// One instance is held by ``AppDependencies`` for the app lifetime and
/// injected into both ``RishiChatService`` and ``VoiceSessionPresenter``.
///
/// Sendable: yes — the only stored property is the `SyncEngine` actor
/// reference, which is itself `Sendable`.
struct AppVoiceDirtyAdapter: ChatDirtyHook, VoiceTranscriptDirtyHook {
    private let syncEngine: SyncEngine

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
    }

    // MARK: - ChatDirtyHook + VoiceTranscriptDirtyHook (same surface)

    func conversationDidUpdate(_ id: ConversationID) async {
        await syncEngine.markConversationDirty(id)
    }

    func messageDidUpdate(_ id: MessageID) async {
        await syncEngine.markMessageDirty(id)
    }
}
