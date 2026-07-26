import Foundation
import Observation
import os.signpost






private let positionSyncSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "position-sync"
)



@MainActor
final class ReaderPositionSyncBinding {

    private let viewModel: ReaderViewModel
    private let syncEngine: SyncEngine
    private var task: Task<Void, Never>?

    init(viewModel: ReaderViewModel, syncEngine: SyncEngine) {
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
            
            
            
            var lastJSON: String? = nil
            while !Task.isCancelled {
                let signpostName: StaticString = "reader.position.poll.tick"
                let signpostState = positionSyncSignposter.beginInterval(signpostName)
                let currentJSON: String? = await MainActor.run {
                    guard let loc = self.viewModel.latestLocator else { return nil as String? }
                    return (try? ReaderPositionLocator(locator: loc).encodedJSONString())
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
