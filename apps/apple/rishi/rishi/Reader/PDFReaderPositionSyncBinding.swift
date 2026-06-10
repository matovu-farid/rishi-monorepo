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
import RishiCore
import RishiReader
import RishiSync

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
        task = Task { [weak self] in
            guard let self else { return }
            var lastSeen: Int = -1
            while !Task.isCancelled {
                let current = await MainActor.run { self.viewModel.pageIndex }
                if current != lastSeen {
                    lastSeen = current
                    await self.syncEngine.markPositionDirty(bookId)
                }
                // Match the reader VM's debounce cadence so we don't poll
                // faster than the engine can act. The engine debounces
                // again on its end so duplicates are cheap.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
