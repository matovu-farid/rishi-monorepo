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
import RishiCore
import RishiReader
import RishiSync

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
        task = Task { [weak self] in
            guard let self else { return }
            // Identity-only change detection — locator JSON strings round-trip
            // 1:1 via the EPUBPositionLocator wrapper so a string compare
            // matches what the writer encodes.
            var lastJSON: String? = nil
            while !Task.isCancelled {
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
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
