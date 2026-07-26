import Foundation





struct AppVoiceDirtyAdapter: ChatDirtyHook, VoiceTranscriptDirtyHook {
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
