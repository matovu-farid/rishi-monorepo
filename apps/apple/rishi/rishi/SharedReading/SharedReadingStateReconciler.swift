import Foundation

struct SharedReadingAuthorityRevision: Equatable, Hashable, Sendable {
    let sessionId: String
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
    let progressSequence: Int64
    var bookId: String? = nil
    var contentHash: String? = nil
}

struct SharedRateMutationFence: Equatable, Sendable {
    let scopeID: UUID
    let revision: UInt64
}

struct SharedReadingControllerPromotionState: Equatable, Sendable {
    let position: SharedReadingDesiredPosition
    let rate: Double
}

enum SharedReadingControllerPromotionPositionSelector {
    static func select(
        isActivelySpeaking: Bool,
        visiblePosition: SharedReadingPosition?,
        narrationPosition: SharedReadingPosition?,
        effectiveRate: Double?
    ) -> SharedReadingControllerPromotionState? {
        guard let rate = effectiveRate else { return nil }
        if isActivelySpeaking, let narrationPosition {
            return .init(position: .init(position: narrationPosition, source: .readAloud), rate: rate)
        }
        guard let visiblePosition else { return nil }
        return .init(position: .init(position: visiblePosition, source: .reader), rate: rate)
    }
}

struct SharedFollowerAudioReconfigurationPlan: Equatable, Sendable {
    let rate: Double
    let cursor: SharedReadingPosition?
    let phase: SharedReadingDesiredPlayback
    let restartAt: SharedReadingPosition?

    static func make(
        rate: Double,
        cursor: SharedReadingPosition?,
        phase: SharedReadingDesiredPlayback,
        rateChanged: Bool,
        cursorNeedsRealignment: Bool
    ) -> Self {
        .init(
            rate: rate,
            cursor: cursor,
            phase: phase,
            restartAt: phase == .playing && (rateChanged || cursorNeedsRealignment) ? cursor : nil
        )
    }
}

struct SharedReadingPosition: Equatable, Hashable, Sendable {
    let href: String
    let page: Int?
    let progression: Double?
}

struct SharedReadingDesiredPosition: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case reader
        case readAloud
    }

    let position: SharedReadingPosition
    let source: Source

    var desiredNarrationCursor: SharedReadingPosition? {
        source == .readAloud ? position : nil
    }
}

enum SharedReadingDesiredPlayback: Equatable, Sendable {
    case paused
    case playing
}

enum SharedReadingObservedPlayback: Equatable, Sendable {
    case noSession
    case playing(UUID)
    case paused(UUID)
}

struct SharedReadingReconcileInput: Equatable, Sendable {
    let authority: SharedReadingAuthorityRevision
    let desiredPosition: SharedReadingDesiredPosition
    let desiredPlayback: SharedReadingDesiredPlayback
    let desiredRate: Double
    let visiblePosition: SharedReadingPosition?
    let narrationPosition: SharedReadingPosition?
    let playback: SharedReadingObservedPlayback
    let effectiveRate: Double?
    var rateIsConfigured: Bool = true
    var audioReady: Bool = true
    var readerReady: Bool = true
}

struct SharedReadingLocalObservation: Equatable, Sendable {
    let visiblePosition: SharedReadingPosition?
    let narrationPosition: SharedReadingPosition?
    let playback: SharedReadingObservedPlayback
    let effectiveRate: Double?
}

struct SharedReadingEffectRevision: Equatable, Hashable, Sendable {
    let authority: SharedReadingAuthorityRevision
    let generation: UInt64
}

enum SharedReadingEffect: Equatable, Hashable, Sendable {
    case navigateVisible(SharedReadingPosition, SharedReadingEffectRevision)
    case setPausedResumeAnchor(SharedReadingPosition, SharedReadingEffectRevision)
    case realignNarration(SharedReadingPosition, SharedReadingEffectRevision)
    case setRate(Double, SharedReadingEffectRevision)
    case startOrResume(SharedReadingPosition, SharedReadingEffectRevision)
    case pause(SharedReadingEffectRevision)

    fileprivate var field: Field {
        switch self {
        case .navigateVisible: .visiblePosition
        case .setPausedResumeAnchor: .narrationPosition
        case .realignNarration: .narrationPosition
        case .setRate: .rate
        case .startOrResume, .pause: .playback
        }
    }

    var revision: SharedReadingEffectRevision {
        switch self {
        case let .navigateVisible(_, revision),
             let .setPausedResumeAnchor(_, revision),
             let .realignNarration(_, revision),
             let .setRate(_, revision): revision
        case let .startOrResume(_, revision), let .pause(revision): revision
        }
    }

    fileprivate enum Field: Hashable, CaseIterable {
        case visiblePosition
        case narrationPosition
        case playback
        case rate
    }
}

struct SharedReadingStateReconciler {
    private struct DesiredState: Equatable {
        let authority: SharedReadingAuthorityRevision
        let position: SharedReadingDesiredPosition
        let playback: SharedReadingDesiredPlayback
        let rate: Double
    }

    private struct Confirmation: Equatable {
        let effect: SharedReadingEffect
        let inputObservation: FieldObservation
    }

    private enum FieldObservation: Equatable {
        case position(SharedReadingPosition?, Bool)
        case playback(SharedReadingObservedPlayback, Bool)
        case rate(Double?, Bool, Bool)
    }

    private(set) var currentRevision: SharedReadingEffectRevision?
    private var currentInput: SharedReadingReconcileInput?
    private var currentDesiredState: DesiredState?
    private var pendingEffects: [SharedReadingEffect.Field: SharedReadingEffect] = [:]
    private var confirmedEffects: [SharedReadingEffect.Field: Confirmation] = [:]
    private var failedObservations: [SharedReadingEffect.Field: FieldObservation] = [:]
    private var generation: UInt64 = 0

    mutating func reconcile(_ input: SharedReadingReconcileInput) -> [SharedReadingEffect] {
        let desiredState = DesiredState(
            authority: input.authority,
            position: input.desiredPosition,
            playback: input.desiredPlayback,
            rate: input.desiredRate
        )
        if currentDesiredState != desiredState {
            generation &+= 1
            currentDesiredState = desiredState
            currentRevision = SharedReadingEffectRevision(authority: input.authority, generation: generation)
            pendingEffects.removeAll()
            confirmedEffects.removeAll()
            failedObservations.removeAll()
        }
        currentInput = input

        guard let revision = currentRevision else { return [] }
        var effects: [SharedReadingEffect] = []

        if input.visiblePosition.map({
            positionsMatch($0, input.desiredPosition.position, source: input.desiredPosition.source)
        }) != true {
            effects.append(.navigateVisible(input.desiredPosition.position, revision))
        }

        if input.audioReady {
            switch input.desiredPlayback {
            case .paused:
                if input.narrationPosition.map({
                    positionsMatch($0, input.desiredPosition.position, source: input.desiredPosition.source)
                }) != true {
                    effects.append(.setPausedResumeAnchor(input.desiredPosition.position, revision))
                }
            case .playing:
                if let desiredCursor = input.desiredPosition.desiredNarrationCursor,
                   input.narrationPosition.map({
                       positionsMatch($0, desiredCursor, source: .readAloud)
                   }) != true,
                   input.playback != .noSession {
                    effects.append(.realignNarration(desiredCursor, revision))
                }
            }

            switch (input.desiredPlayback, input.playback) {
            case (.playing, .noSession), (.playing, .paused):
                effects.append(.startOrResume(input.desiredPosition.position, revision))
            case (.paused, .playing):
                effects.append(.pause(revision))
            case (.playing, .playing), (.paused, .paused), (.paused, .noSession):
                break
            }

            if input.rateIsConfigured,
               let effectiveRate = input.effectiveRate,
               abs(effectiveRate - input.desiredRate) <= 0.0001 {
                // The local rate already confirms the desired value.
            } else {
                effects.append(.setRate(input.desiredRate, revision))
            }
        }

        let candidateFields = Set(effects.map(\.field))
        for field in SharedReadingEffect.Field.allCases where !candidateFields.contains(field) {
            pendingEffects.removeValue(forKey: field)
            confirmedEffects.removeValue(forKey: field)
            if failedObservations[field] != fieldObservation(field, in: input) {
                failedObservations.removeValue(forKey: field)
            }
        }

        return effects.filter { effect in
            let field = effect.field
            let observation = fieldObservation(field, in: input)

            if let confirmation = confirmedEffects[field] {
                if confirmation.effect == effect, confirmation.inputObservation == observation {
                    return false
                }
                confirmedEffects.removeValue(forKey: field)
            }
            if let failedObservation = failedObservations[field] {
                if failedObservation == observation {
                    return false
                }
                failedObservations.removeValue(forKey: field)
            }
            if let pending = pendingEffects[field], pending == effect { return false }
            pendingEffects[effect.field] = effect
            return true
        }
    }

    @discardableResult
    mutating func complete(
        _ effect: SharedReadingEffect,
        succeeded: Bool,
        observation: SharedReadingLocalObservation
    ) -> Bool {
        guard currentInput != nil,
              currentRevision == effect.revision,
              pendingEffects[effect.field] == effect else { return false }

        pendingEffects.removeValue(forKey: effect.field)
        guard succeeded, confirms(effect, with: observation) else {
            failedObservations[effect.field] = currentInput.map { fieldObservation(effect.field, in: $0) }
            return false
        }

        if let currentInput {
            confirmedEffects[effect.field] = Confirmation(
                effect: effect,
                inputObservation: fieldObservation(effect.field, in: currentInput)
            )
        }
        return true
    }

    @discardableResult
    mutating func deferAcceptedNavigation(
        _ effect: SharedReadingEffect,
        observedPosition: SharedReadingPosition?
    ) -> Bool {
        guard case .navigateVisible = effect,
              currentRevision == effect.revision,
              pendingEffects[.visiblePosition] == effect,
              let currentInput else { return false }

        pendingEffects.removeValue(forKey: .visiblePosition)
        if observedPosition.map({
            positionsMatch($0, currentInput.desiredPosition.position, source: currentInput.desiredPosition.source)
        }) == true {
            failedObservations.removeValue(forKey: .visiblePosition)
        } else {
            failedObservations[.visiblePosition] = .position(observedPosition, currentInput.readerReady)
        }
        return true
    }

    private func fieldObservation(_ field: SharedReadingEffect.Field, in input: SharedReadingReconcileInput) -> FieldObservation {
        switch field {
        case .visiblePosition: .position(input.visiblePosition, input.readerReady)
        case .narrationPosition: .position(input.narrationPosition, input.audioReady)
        case .playback: .playback(input.playback, input.audioReady)
        case .rate: .rate(input.effectiveRate, input.rateIsConfigured, input.audioReady)
        }
    }

    private func positionsMatch(
        _ lhs: SharedReadingPosition,
        _ rhs: SharedReadingPosition,
        source: SharedReadingDesiredPosition.Source
    ) -> Bool {
        guard lhs.href == rhs.href, lhs.page == rhs.page else { return false }
        switch source {
        case .reader:
            return lhs.progression == rhs.progression
        case .readAloud:
            guard let left = lhs.progression, let right = rhs.progression else {
                return lhs.progression == rhs.progression
            }
            return abs(left - right) <= 0.08
        }
    }

    private func confirms(_ effect: SharedReadingEffect, with observation: SharedReadingLocalObservation) -> Bool {
        switch effect {
        case let .navigateVisible(target, _):
            return observation.visiblePosition.map {
                positionsMatch($0, target, source: currentInput?.desiredPosition.source ?? .reader)
            } ?? false
        case let .setPausedResumeAnchor(target, _), let .realignNarration(target, _):
            return observation.narrationPosition.map {
                positionsMatch($0, target, source: currentInput?.desiredPosition.source ?? .reader)
            } ?? false
        case let .setRate(target, _):
            return observation.effectiveRate.map { abs($0 - target) <= 0.0001 } ?? false
        case let .startOrResume(target, _):
            guard case .playing = observation.playback,
                  let narrationPosition = observation.narrationPosition else { return false }
            return positionsMatch(
                narrationPosition,
                target,
                source: currentInput?.desiredPosition.source ?? .reader
            )
        case .pause:
            if case .paused = observation.playback { return true }
            return false
        }
    }
}
