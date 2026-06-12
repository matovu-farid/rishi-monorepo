//
//  AppChatRefreshAdapter.swift
//  rishi
//
//  Phase 16-05 — bridges `RishiSync.ChatSyncRefreshDelegate` to whichever
//  `ConversationsListViewModel` the Conversations tab currently has
//  mounted. RootView (or the Conversations tab host) calls
//  `setActive(_:)` when the VM appears / disappears; the adapter
//  forwards `chatSyncDidMerge()` to that VM so the Conversations list
//  re-reads from the store after an inbound merge.
//
//  Threading: explicitly `@MainActor`. Explicit `Sendable` conformance
//  (inherited from `ChatSyncRefreshDelegate: Sendable`) overrides the
//  module's default-isolation = MainActor inference, so without this
//  annotation the class would be treated as nonisolated-Sendable and
//  mutable stored properties would be rejected. With `@MainActor` the
//  isolation provides the safety: Sendable conformance is implicit, and
//  the `SyncEngine` actor's `await delegate.chatSyncDidMerge()` hops to
//  MainActor once on entry. No lock required.
//

import Foundation
import RishiChat
import RishiCore
import RishiSync

@MainActor
final class AppChatRefreshAdapter: ChatSyncRefreshDelegate {

    private weak var activeViewModel: ConversationsListViewModel?
    private var activeUserId: UserID?

    init() {}

    /// Called from RootView / the Conversations tab when the VM mounts.
    /// `userId` is captured here so we can forward to `refreshAfterSync`
    /// from the engine actor without RootView having to hand the user id
    /// back through the bridge.
    func setActive(viewModel: ConversationsListViewModel, userId: UserID) {
        activeViewModel = viewModel
        activeUserId = userId
    }

    /// Called from RootView / the Conversations tab when the VM goes
    /// away (tab switched, sign-out). Safe to call multiple times.
    func clearActive() {
        activeViewModel = nil
        activeUserId = nil
    }

    // MARK: - ChatSyncRefreshDelegate

    func chatSyncDidMerge() async {
        guard let vm = activeViewModel, let userId = activeUserId else { return }
        await vm.refreshAfterSync(userId: userId)
    }
}
