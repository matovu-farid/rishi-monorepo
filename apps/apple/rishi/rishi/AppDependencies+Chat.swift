import Foundation
import RishiCore
import RishiChat
import RishiVoice

// MARK: - Chat / voice forwarder accessors

extension AppDependencies {
    var conversationStore: any ConversationStore { services!.conversationStore }
    var messageStore: any MessageStore { services!.messageStore }
    var conversationLookup: ConversationLookup { services!.conversationLookup }
    var voiceDirtyAdapter: AppVoiceDirtyAdapter { services!.voiceDirtyAdapter }
    var chatService: RishiChatService { services!.chatService }
    var chatPresenter: ChatPresenterImpl { services!.chatPresenter }
    var voicePresenter: VoiceSessionPresenter { services!.voicePresenter }
}
