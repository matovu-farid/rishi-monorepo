

import Foundation




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

    

    nonisolated func chatSyncDidMerge() async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            guard let vm = activeViewModel, let userId = activeUserId else { return }
            Task { await vm.refreshAfterSync(userId: userId) }
        }
    }
}
