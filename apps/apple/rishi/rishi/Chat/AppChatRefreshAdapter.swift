import Foundation

@MainActor
final class AppChatRefreshAdapter: ChatSyncRefreshDelegate {
    private weak var activeViewModel: ConversationsListViewModel?
    private var activeUserId: UserID?
    private var activationID: UUID?

    nonisolated init() {}

    @discardableResult
    func setActive(viewModel: ConversationsListViewModel, userId: UserID) -> UUID {
        let id = UUID()
        activationID = id
        activeViewModel = viewModel
        activeUserId = userId
        return id
    }

    func clearActive(ifActivation id: UUID) {
        guard activationID == id else { return }
        activationID = nil
        activeViewModel = nil
        activeUserId = nil
    }

    /// Retains no presentation; validates its captured registration before starting I/O.
    @discardableResult
    func enqueueRefresh() -> Task<Void, Never>? {
        guard let id = activationID, let vm = activeViewModel, let userId = activeUserId else { return nil }
        return Task { [weak self, weak vm] in
            guard let self, let vm, self.activationID == id,
                  self.activeViewModel === vm, self.activeUserId == userId else { return }
            await vm.refreshAfterSync(userId: userId)
        }
    }

    nonisolated func chatSyncDidMerge() async {
        await MainActor.run { [weak self] in _ = self?.enqueueRefresh() }
    }
}
