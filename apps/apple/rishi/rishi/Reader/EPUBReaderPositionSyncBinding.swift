//
//  EPUBReaderPositionSyncBinding.swift
//  rishi
//
//  Phase 7 Plan 07-05 — SYNC-03 wiring on the EPUB reader.
//
//  Mirrors the PDF version against `EPUBReaderViewModel.latestLocator`. The
//  Readium `Locator` is non-Sendable, but we only need its identity to detect
//  change — we forward the book id (Sendable) to `SyncEngine.markPositionDirty`
//  and the engine reads the actual Position row from the local store when it
//  builds the upload payload.
//

import Foundation
import Observation
import os.signpost
import RishiCore
import RishiReader
import RishiSync

// Phase 19 Plan 19-06 — F-P0-07: native OSSignposter so Instruments can attribute
// the poll-tick wake rate during cold-launch / reader-running captures.
private let positionSyncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "position-sync"
)

// v1.1 backlog: replace 250ms poll with push-based AsyncStream<Locator>; see apps/apple/docs/SWIFT-CONCURRENCY-RULES.md §"Position-sync polling".
/// Owned by `RootView` while an EPUB reader sheet is on screen.
@MainActor
final class EPUBReaderPositionSyncBinding {

    private let viewModel: EPUBReaderViewModel
    private let syncEngine: SyncEngine
    private var task: Task<Void, Never>?

    init(viewModel: EPUBReaderViewModel, syncEngine: SyncEngine) {
        self.viewModel = viewModel
        self.syncEngine = syncEngine
        start()
    }

    deinit {
        task?.cancel()
    }

    private func start() {
        let bookId = viewModel.book.id
        // KEEP: F-P0-06 audit — poll loop reads `latestLocator` via
        // `MainActor.run` (locator JSON encode runs on main; F-P0-07
        // backlog tracks moving this to push observation). UI-state
        // read + actor hop into syncEngine; no detached work needed.
        task = Task { [weak self] in
            guard let self else { return }
            // Identity-only change detection — locator JSON strings round-trip
            // 1:1 via the EPUBPositionLocator wrapper so a string compare
            // matches what the writer encodes.
            var lastJSON: String? = nil
            while !Task.isCancelled {
                let signpostName: StaticString = "epub.position.poll.tick"
                let signpostState = positionSyncSignposter.beginInterval(signpostName)
                let currentJSON: String? = await MainActor.run {
                    guard let loc = self.viewModel.latestLocator else { return nil as String? }
                    return (try? EPUBPositionLocator(locator: loc).encodedJSONString())
                }
                if currentJSON != lastJSON {
                    lastJSON = currentJSON
                    if currentJSON != nil {
                        await self.syncEngine.markPositionDirty(bookId)
                    }
                }
                positionSyncSignposter.endInterval(signpostName, signpostState)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
