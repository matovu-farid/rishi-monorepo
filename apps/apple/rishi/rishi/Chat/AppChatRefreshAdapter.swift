//
//  AppChatRefreshAdapter.swift
//  rishi
//
//  Phase 16-05 — bridges `RishiSync.ChatSyncRefreshDelegate` to whichever
//  `ConversationsListViewModel` the Conversations tab currently has
//  mounted. RootView (or the Conversations tab host) calls
//  `setActive(_:)` when the VM appears / disappears; the adapter
//  forwards `chatSyncDidMerge()` to that VM on the MainActor so the
//  Conversations list re-reads from the store after an inbound merge.
//
//  Threading: the adapter is a `final class @unchecked Sendable` so the
//  `SyncEngine` actor can hold it as `any ChatSyncRefreshDelegate?` and
//  cross actor boundaries. Mutation of `activeViewModel` is guarded by
//  an `OSAllocatedUnfairLock` and the actual refresh call hops to
//  MainActor inside `chatSyncDidMerge()`.
//

import Foundation
import os
import RishiChat
import RishiCore
import RishiSync

final class AppChatRefreshAdapter: ChatSyncRefreshDelegate, @unchecked Sendable {

    /// Lock-guarded weak handle to the currently-mounted VM + the user
    /// whose conversations it's showing. RootView sets this when the
    /// Conversations tab `.task` fires; clears it when the tab is torn
    /// down.
    private struct Active {
        weak var viewModel: ConversationsListViewModel?
        let userId: UserID
    }

    private let state = OSAllocatedUnfairLock<Active?>(initialState: nil)

    init() {}

    /// Called from RootView / the Conversations tab when the VM mounts.
    /// `userId` is captured here so we can forward to `refreshAfterSync`
    /// from the engine actor without RootView having to hand the user id
    /// back through the bridge.
    func setActive(viewModel: ConversationsListViewModel, userId: UserID) {
        state.withLock { $0 = Active(viewModel: viewModel, userId: userId) }
    }

    /// Called from RootView / the Conversations tab when the VM goes
    /// away (tab switched, sign-out). Safe to call multiple times.
    func clearActive() {
        state.withLock { $0 = nil }
    }

    // MARK: - ChatSyncRefreshDelegate

    func chatSyncDidMerge() async {
        let captured = state.withLock { $0 }
        guard let active = captured, let vm = active.viewModel else { return }
        await vm.refreshAfterSync(userId: active.userId)
    }
}
