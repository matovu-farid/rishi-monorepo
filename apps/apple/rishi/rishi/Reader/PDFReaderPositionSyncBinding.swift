

















import Foundation
import Observation
import os.signpost
import RishiCore
import RishiReader
import RishiSync



private let positionSyncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "position-sync"
)




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
                let signpostName: StaticString = "pdf.position.poll.tick"
                let signpostState = positionSyncSignposter.beginInterval(signpostName)
                let current = await MainActor.run { self.viewModel.pageIndex }
                if current != lastSeen {
                    lastSeen = current
                    await self.syncEngine.markPositionDirty(bookId)
                }
                positionSyncSignposter.endInterval(signpostName, signpostState)
                
                
                
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
