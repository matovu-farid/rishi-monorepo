import Foundation
import Observation
import os.signpost

private let positionSyncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "position-sync"
)

@MainActor
final class ReaderPositionSyncBinding {
    typealias DirtyMark = @MainActor (BookID) async -> Void
    typealias PollWait = @Sendable () async throws -> Void

    private let viewModel: ReaderViewModel
    private let sourceLease: BookSourceLease
    private let markDirty: DirtyMark
    private var task: Task<Void, Never>?
    private var isStopped = false

    convenience init(viewModel: ReaderViewModel, syncEngine: SyncEngine, sourceLease: BookSourceLease) {
        self.init(viewModel: viewModel, sourceLease: sourceLease,
                  markDirty: { await syncEngine.markPositionDirty($0) })
    }

    init(
        viewModel: ReaderViewModel,
        sourceLease: BookSourceLease,
        markDirty: @escaping DirtyMark,
        pollWait: @escaping PollWait = { try await Task.sleep(nanoseconds: 250_000_000) }
    ) {
        self.viewModel = viewModel
        self.sourceLease = sourceLease
        self.markDirty = markDirty
        task = Task { [weak self] in
            var lastJSON: String?
            while !Task.isCancelled {
                // The finite call owns self through admitted work only. It
                // returns a value before the wait, leaving no polling cycle.
                guard let result = await self?.poll(lastJSON: lastJSON) else { return }
                lastJSON = result.json
                guard result.shouldContinue, !Task.isCancelled else { return }
                do { try await pollWait() } catch { return }
            }
        }
    }

    deinit { task?.cancel() }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        task?.cancel()
        task = nil
    }

    private func poll(lastJSON: String?) async -> (json: String?, shouldContinue: Bool) {
        let signpostName: StaticString = "reader.position.poll.tick"
        let signpostState = positionSyncSignposter.beginInterval(signpostName)
        defer { positionSyncSignposter.endInterval(signpostName, signpostState) }
        guard !isStopped, !Task.isCancelled else { return (lastJSON, false) }
        let currentJSON = viewModel.latestLocator.flatMap {
            try? ReaderPositionLocator(locator: $0).encodedJSONString()
        }
        if currentJSON != lastJSON, currentJSON != nil {
            guard !isStopped, !Task.isCancelled,
                  let admission = try? sourceLease.effectAuthority.admit(sourceLease.sourceAccessPermit)
            else { return (lastJSON, false) }
            defer { admission.release() }
            guard !isStopped, !Task.isCancelled else { return (lastJSON, false) }
            await markDirty(viewModel.book.id)
        }
        return (currentJSON, !isStopped && !Task.isCancelled)
    }
}
