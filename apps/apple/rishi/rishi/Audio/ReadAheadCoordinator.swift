

import Foundation
import RishiAudio


@MainActor
final class ReadAheadCoordinator {

    private let prewarmer: TTSPrewarmer

    var readAhead: Int

    init(prewarmer: TTSPrewarmer, readAhead: Int = 5) {
        self.prewarmer = prewarmer
        self.readAhead = readAhead
    }


    func warm(
        after index: Int,
        in paragraphs: [String],
        voice: String,
        model: String,
        speed: Double
    ) async {
        let windowStart = index + 1
        let upper = min(windowStart + readAhead, paragraphs.count)
        if windowStart < upper {
            let window = paragraphs[windowStart..<upper].map { text in
                TTSStreamRequest(
                    text: text,
                    voice: voice,
                    model: model,
                    speed: speed,
                    passageId: nil
                )
            }
            await prewarmer.warm(requests: window)
        } else {
            await prewarmer.warm(requests: [])
        }
    }

  
    func cancelAll() async {
        await prewarmer.cancelAll()
    }
}
