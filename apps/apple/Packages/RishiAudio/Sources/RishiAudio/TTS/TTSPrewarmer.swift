import Foundation
import RishiLogging

/// Drains `TTSChunkSource.stream(request:)` for paragraphs ahead of the play head
/// for the side effect: in production wiring the source is `CachingTTSChunkSource`,
/// so a miss synthesises + writes the MP3 to disk and a hit is a no-op. The
/// prewarmer is intentionally dumb — it does not know about the cache, the decoder,
/// or the audio engine. It just drains ordered chunks and discards them.
public actor TTSPrewarmer {

    private let source: any TTSChunkSource
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var inFlightRequests: [TTSStreamRequest] = []
    private var requestsByID: [UUID: TTSStreamRequest] = [:]

    public init(source: any TTSChunkSource) {
        self.source = source
    }

    /// Spin one Task per request that drains `source.stream(request:)` to completion.
    /// Each Task is registered in `inFlight` under a per-call UUID and removes its own
    /// entry on exit (success, error, or cancellation). Returns once all per-request
    /// Tasks are SPAWNED — does NOT await their completion. Repeated `warm` calls for
    /// the same `TTSStreamRequest` are allowed; the cache layer makes duplicate drains
    /// cheap (hit fast-path or in-flight de-dup).
    public func warm(requests: [TTSStreamRequest]) async {
        for req in requests {
            guard await source.shouldShowLoading(for: req) else { continue }
            guard !inFlightRequests.contains(where: { $0 == req }) else { continue }
            let id = UUID()
            let source = self.source
            inFlightRequests.append(req)
            requestsByID[id] = req
            let task = Task<Void, Never> { [weak self] in
                defer {
                    Task { [weak self] in await self?.removeInFlight(id: id) }
                }
                do {
                    for try await _ in await source.stream(request: req) {
                        if Task.isCancelled { return }
                        // Drain only — bytes discarded. Side effect is the cache write.
                    }
                } catch {
                    // Errors are logged but not propagated — prewarm is best-effort.
                    Log.event("tts.prewarm.failed", level: .debug, data: [
                        "error": String(describing: error)
                    ])
                }
            }
            inFlight[id] = task
        }
    }

    /// Cancels all in-flight prewarm Tasks and clears the table. Does NOT await
    /// per-Task completion (cancellation is cooperative — streams exit on their next
    /// `await`). Callers that need to be sure tasks have wound down should poll
    /// `inFlightCount` after this returns.
    public func cancelAll() async {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        inFlightRequests.removeAll()
        requestsByID.removeAll()
    }

    /// Test/internal visibility hook — number of Tasks still registered. Production
    /// callers do not consult this; tests poll it to assert settle.
    internal var inFlightCount: Int { inFlight.count }

    private func removeInFlight(id: UUID) {
        inFlight.removeValue(forKey: id)
        if let request = requestsByID.removeValue(forKey: id) {
            inFlightRequests.removeAll { $0 == request }
        }
    }
}
