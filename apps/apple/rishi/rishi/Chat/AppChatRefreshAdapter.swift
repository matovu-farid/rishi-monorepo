

import Foundation
import RishiChat
import RishiCore
import RishiSync

@MainActor
final class AppChatRefreshAdapter: ChatSyncRefreshDelegate {

    private weak var activeViewModel: ConversationsListViewModel?
    private var activeUserId: UserID?


    nonisolated init() {}


    func setActive(viewModel: ConversationsListViewModel, userId: UserID) {
        activeViewModel = viewModel
        activeUserId = userId
    }


    func clearActive() {
        activeViewModel = nil
        activeUserId = nil
    }

    

    func chatSyncDidMerge() async {
        guard let vm = activeViewModel, let userId = activeUserId else { return }
        await vm.refreshAfterSync(userId: userId)
    }
}
