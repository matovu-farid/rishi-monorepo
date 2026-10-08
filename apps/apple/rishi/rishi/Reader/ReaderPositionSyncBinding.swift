import Foundation
import os.signpost

private let positionSyncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "position-sync"
)

/// Publishes the exact saved snapshot under one destination-owned callback.
@MainActor
final class ReaderPositionSyncBinding {
    typealias Commit = ReaderViewModel.PersistedPositionHandler
    private let owner = UUID()
    private weak var viewModel: ReaderViewModel?
    private var isStopped = false

    convenience init(
        viewModel: ReaderViewModel, syncEngine: SyncEngine,
        sourceLease: BookSourceLease, scopedMutationStore: BookScopedMutationStore
    ) {
        let authority: ReaderPositionPublicationAuthority?
        switch sourceLease.access {
        case .account(let permit):
            let invalidation = sourceLease.owner.invalidation
            authority = scopedMutationStore.publicationAuthority(
                permit: permit, source: sourceLease.sourceAccessPermit,
                validateSource: {
                    guard !invalidation.isInvalidated else { throw BookSourceAccessError.revoked }
                }
            )
        case .localPreview:
            authority = nil
        }
        self.init(viewModel: viewModel, sourceLease: sourceLease) { position, persist in
            guard let authority else {
                try await persist()
                return .committed
            }
            return try await syncEngine.commitReaderPosition(position, authority: authority, persist: persist)
        }
    }

    init(viewModel: ReaderViewModel, sourceLease: BookSourceLease, commit: @escaping Commit) {
        self.viewModel = viewModel
        viewModel.installPersistedPositionHandler(owner: owner) { position, persist in
            let name: StaticString = "reader.position.commit"
            let state = positionSyncSignposter.beginInterval(name)
            defer { positionSyncSignposter.endInterval(name, state) }
            // Capture the lease only in the finite callback. The engine's
            // deferred registry receives immutable authority, never this lease.
            let admission = try sourceLease.effectAuthority.admit(sourceLease.sourceAccessPermit)
            defer { admission.release() }
            return try await commit(position, persist)
        }
    }

    deinit {
        // Default MainActor isolation cannot be assumed from a nonisolated
        // deinit. The callback does not capture this binding, avoiding a cycle.
        let owner = owner
        let reader = viewModel
        Task { @MainActor in reader?.clearPersistedPositionHandler(ifOwner: owner) }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        viewModel?.clearPersistedPositionHandler(ifOwner: owner)
    }
}
