import Foundation


struct AdvanceWatcherDecision {

    enum Action: Equatable {
        case wait
        case advance
        case bail
    }

    private let targetPassageId: String?
    private var hasStarted = false

    init() {
        self.targetPassageId = nil
    }

    init(targetPassageId: String) {
        self.targetPassageId = targetPassageId
    }

    mutating func observe(_ status: TTSStatus) -> Action {
        observe(status: status, passageId: nil)
    }

    mutating func observe(status: TTSStatus, passageId: String?) -> Action {
        if status == .error {
            return .bail
        }

        if status == .paused {
            return .wait
        }

        if status == .loading || status == .playing {
            if targetPassageId == nil || passageId == targetPassageId {
                hasStarted = true
            }
        }

        if status == .stopped {

            if let target = targetPassageId, passageId == target {
                return .advance
            }

            if hasStarted {
                return .advance
            }
        }

        return .wait
    }
}

@MainActor
final class ParagraphAdvanceWatcher {

    private let state: TTSPlaybackState
    private var advanceTask: Task<Void, Never>?

    init(state: TTSPlaybackState) {
        self.state = state
    }

    func start(targetPassageId: String, onAdvance: @escaping () async -> Void) {
        advanceTask?.cancel()

        advanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var decision = AdvanceWatcherDecision(
                targetPassageId: targetPassageId
            )
            while !Task.isCancelled {
                switch decision.observe(
                    status: self.state.status,
                    passageId: self.state.currentPassageId
                ) {
                case .advance:
                    await onAdvance()
                    return
                case .bail:
                    return
                case .wait:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    func cancel() {
        advanceTask?.cancel()
        advanceTask = nil
    }
}
