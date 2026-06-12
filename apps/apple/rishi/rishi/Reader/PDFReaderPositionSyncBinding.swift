//
//  PDFReaderPositionSyncBinding.swift
//  rishi
//
//  Phase 7 Plan 07-05 — SYNC-03 wiring on the PDF reader.
//
//  Observes `PDFReaderViewModel.pageIndex` via the `Observation` framework and
//  forwards every distinct page change to `SyncEngine.markPositionDirty(_:)`.
//  The engine's `PositionDebouncer` collapses the resulting flurry into one
//  metadata + queue mark per debounce window (1s default) — this binding is
//  intentionally chatty so the engine owns the single coalesce point.
//
//  RishiReader has zero knowledge of RishiSync; we keep that invariant by
//  hosting the bridge in the rishi target. The binding is created at the
//  reader-screen presentation site (RootView) and stays alive for the
//  lifetime of the reader sheet.
//

import Foundation
import Observation
import os.signpost
import RishiCore
import RishiReader
import RishiSync

// Phase 19 Plan 19-06 — F-P1-02: native OSSignposter so Instruments can attribute
// the poll-tick wake rate during cold-launch / reader-running captures.
private let positionSyncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "position-sync"
)

// v1.1 backlog: replace 250ms poll with push-based AsyncStream<Locator>; see apps/apple/docs/SWIFT-CONCURRENCY-RULES.md §"Position-sync polling".
/// Owned by `RootView` while a PDF reader sheet is on screen. Cancels its
/// poll task on `deinit` so dismissed readers stop pushing.
@MainActor
final class PDFReaderPositionSyncBinding {

    private let viewModel: PDFReaderViewModel
    private let syncEngine: SyncEngine
    private var task: Task<Void, Never>?

    init(viewModel: PDFReaderViewModel, syncEngine: SyncEngine) {
        self.viewModel = viewModel
        self.syncEngine = syncEngine
        start()
    }

    deinit {
        task?.cancel()
    }

    private func start() {
        let bookId = viewModel.book.id
        // KEEP: F-P0-06 audit — poll loop reads `pageIndex` via
        // `MainActor.run` and hops into the syncEngine actor. UI-state
        // read + actor hop; no detached work. (v1.1: push-observation
        // replacement tracked in the file-level backlog comment above.)
        task = Task { [weak self] in
            guard let self else { return }
            var lastSeen: Int = -1
            while !Task.isCancelled {
                let signpostName: StaticString = "pdf.position.poll.tick"
                let signpostState = positionSyncSignposter.beginInterval(signpostName)
                let current = await MainActor.run { self.viewModel.pageIndex }
                if current != lastSeen {
                    lastSeen = current
                    await self.syncEngine.markPositionDirty(bookId)
                }
                positionSyncSignposter.endInterval(signpostName, signpostState)
                // Match the reader VM's debounce cadence so we don't poll
                // faster than the engine can act. The engine debounces
                // again on its end so duplicates are cheap.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
