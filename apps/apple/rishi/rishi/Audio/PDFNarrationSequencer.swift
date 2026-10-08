import Foundation

struct PDFNarrationSkipRequest {
    let delta: Int
    let playbackToken: UUID
    let playbackGeneration: UInt64
    let lease: RemoteCommandLease?
}

/// Owns relative PDF skip ordering. Playback and native synthesizers remain
/// controller-owned and are checked through the four callbacks.
@MainActor
final class PDFNarrationSequencer {
    private let isCurrent: @MainActor (PDFNarrationSkipRequest, ObjectIdentifier) -> Bool
    private let resolve: @MainActor (PDFNarrationCursor, Int) async -> PDFNarrationTarget?
    private let apply: @MainActor (PDFNarrationTarget, ObjectIdentifier) -> ObjectIdentifier?
    private let stopAtEnd: @MainActor (RemoteCommandLease?) async -> Void
    private var steps: [PDFNarrationSkipRequest] = []
    private var drainTask: Task<Void, Never>?
    private var drainID: UUID?
    private var expectedSynthesizerID: ObjectIdentifier?
    private var logicalCursor: PDFNarrationCursor?

    init(
        isCurrent: @escaping @MainActor (PDFNarrationSkipRequest, ObjectIdentifier) -> Bool,
        resolve: @escaping @MainActor (PDFNarrationCursor, Int) async -> PDFNarrationTarget?,
        apply: @escaping @MainActor (PDFNarrationTarget, ObjectIdentifier) -> ObjectIdentifier?,
        stopAtEnd: @escaping @MainActor (RemoteCommandLease?) async -> Void
    ) {
        self.isCurrent = isCurrent
        self.resolve = resolve
        self.apply = apply
        self.stopAtEnd = stopAtEnd
    }

    func enqueue(_ request: PDFNarrationSkipRequest, initialCursor: PDFNarrationCursor?, synthesizerID: ObjectIdentifier) {
        guard request.delta == -1 || request.delta == 1,
              request.lease?.isValid ?? true else { return }
        if drainTask == nil {
            guard let initialCursor else { return }
            logicalCursor = initialCursor
            expectedSynthesizerID = synthesizerID
            let id = UUID()
            drainID = id
            drainTask = Task { [weak self] in await self?.drain(ownerID: id) }
        }
        steps.append(request)
    }

    func cancel() {
        steps.removeAll()
        drainTask?.cancel()
        drainTask = nil
        drainID = nil
        expectedSynthesizerID = nil
        logicalCursor = nil
    }

    /// A completion barrier for the current worker, without starting work.
    func currentDrainCompletion() -> Task<Void, Never>? { drainTask }

    private func drain(ownerID: UUID) async {
        defer {
            if drainID == ownerID {
                drainTask = nil
                drainID = nil
                expectedSynthesizerID = nil
                logicalCursor = nil
            }
        }
        while !Task.isCancelled, drainID == ownerID, !steps.isEmpty {
            let step = steps.removeFirst()
            guard step.lease?.isValid ?? true,
                  let expectedSynthesizerID,
                  isCurrent(step, expectedSynthesizerID),
                  let logicalCursor else { continue }
            let target = await resolve(logicalCursor, step.delta)
            guard !Task.isCancelled, drainID == ownerID,
                  step.lease?.isValid ?? true,
                  isCurrent(step, expectedSynthesizerID) else { return }
            guard let target else {
                if step.delta > 0 { await stopAtEnd(step.lease) }
                return
            }
            self.logicalCursor = PDFNarrationCursor(page: target.page, ordinal: target.ordinal)
            guard let replacementID = apply(target, expectedSynthesizerID),
                  !Task.isCancelled, drainID == ownerID else { return }
            self.expectedSynthesizerID = replacementID
        }
    }
}
