#if canImport(UIKit)
import Foundation
import UIKit
import ReadiumShared

struct SharedNavigationIdentity: Equatable {
    let sessionID: String
    let request: SharedReaderNavigationRequest
}

struct SharedNavigationNativeIdentity: Equatable {
    let navigator: ObjectIdentifier
    let container: ObjectIdentifier
}

struct SharedNavigationFlight {
    let id: UUID
    let generation: UUID
    let input: SharedNavigationIdentity
    let native: SharedNavigationNativeIdentity
    let task: Task<Void, Never>
}

struct SharedNavigationState {
    enum Lifecycle: Equatable { case inactive, active, retired }
    var lifecycle: Lifecycle = .inactive
    var generation = UUID()
    var sessionID: String?
    var isFollower = false
    var request: SharedReaderNavigationRequest?
    var onResult: ((SharedReaderNavigationResult) -> Void)?
    var pending: SharedNavigationIdentity?
    var consumed: SharedNavigationIdentity?
    var flight: SharedNavigationFlight?
    var isReady = false
    var lastNative: SharedNavigationNativeIdentity?
    #if DEBUG
    var navigationForTesting: (@MainActor (Locator) async -> Bool)?
    var nativeIdentityForTesting: SharedNavigationNativeIdentity?
    #endif
}

extension ReaderNavigatorCoordinator {
    func updateSharedNavigation(
        request: SharedReaderNavigationRequest?, sessionID: String?,
        isFollower: Bool, onResult: ((SharedReaderNavigationResult) -> Void)?
    ) {
        guard sharedNavigation.lifecycle != .retired else { return }
        if sharedNavigation.sessionID != sessionID || sharedNavigation.isFollower != isFollower {
            advanceSharedNavigationGeneration()
        }
        sharedNavigation.sessionID = sessionID
        sharedNavigation.isFollower = isFollower
        sharedNavigation.request = request
        sharedNavigation.onResult = onResult
        queueCurrentSharedNavigation()
        drainSharedNavigationIfEligible()
    }

    func setSharedNavigationActive(_ active: Bool) {
        guard sharedNavigation.lifecycle != .retired else { return }
        let lifecycle: SharedNavigationState.Lifecycle = active ? .active : .inactive
        guard sharedNavigation.lifecycle != lifecycle else { return }
        advanceSharedNavigationGeneration()
        sharedNavigation.lifecycle = lifecycle
        queueCurrentSharedNavigation()
        drainSharedNavigationIfEligible()
    }

    /// Attachment and input refresh are one synchronous representable update.
    func sharedNavigationNavigatorWillUpdate() {
        guard sharedNavigation.lifecycle != .retired else { return }
        sharedNavigation.isReady = false
    }

    func sharedNavigationNavigatorDidBecomeReady() {
        guard sharedNavigation.lifecycle != .retired else { return }
        guard let native = currentSharedNavigationNativeIdentity else {
            sharedNavigation.isReady = false
            return
        }
        if sharedNavigation.lastNative != native {
            advanceSharedNavigationGeneration()
            sharedNavigation.lastNative = native
        }
        sharedNavigation.isReady = true
        queueCurrentSharedNavigation()
        drainSharedNavigationIfEligible()
    }

    func retireSharedNavigation() {
        guard sharedNavigation.lifecycle != .retired else { return }
        advanceSharedNavigationGeneration()
        sharedNavigation.lifecycle = .retired
        sharedNavigation.request = nil
        sharedNavigation.onResult = nil
        sharedNavigation.isReady = false
        // Native go is uncancelable. Retain its barrier until it returns;
        // retirement suppresses delivery and prevents another submission.
    }

    private var currentSharedNavigationInput: SharedNavigationIdentity? {
        guard sharedNavigation.isFollower,
              let sessionID = sharedNavigation.sessionID, !sessionID.isEmpty,
              let request = sharedNavigation.request else { return nil }
        return SharedNavigationIdentity(sessionID: sessionID, request: request)
    }

    private var currentSharedNavigationNativeIdentity: SharedNavigationNativeIdentity? {
        #if DEBUG
        if let identity = sharedNavigation.nativeIdentityForTesting { return identity }
        #endif
        guard let navigator, let container = navigator.parent else { return nil }
        return SharedNavigationNativeIdentity(
            navigator: ObjectIdentifier(navigator), container: ObjectIdentifier(container))
    }

    private func advanceSharedNavigationGeneration() {
        sharedNavigation.generation = UUID()
        sharedNavigation.pending = nil
        sharedNavigation.consumed = nil
    }

    private func queueCurrentSharedNavigation() {
        guard sharedNavigation.lifecycle == .active,
              let input = currentSharedNavigationInput else {
            sharedNavigation.pending = nil
            return
        }
        if sharedNavigation.consumed == input ||
            (sharedNavigation.flight?.generation == sharedNavigation.generation &&
             sharedNavigation.flight?.input == input) {
            sharedNavigation.pending = nil
            return
        }
        sharedNavigation.pending = input
    }

    private func drainSharedNavigationIfEligible() {
        guard sharedNavigation.lifecycle == .active, sharedNavigation.isReady,
              sharedNavigation.flight == nil, viewModel.publication != nil,
              let input = sharedNavigation.pending, input == currentSharedNavigationInput,
              let native = currentSharedNavigationNativeIdentity else { return }
        let id = UUID()
        let generation = sharedNavigation.generation
        sharedNavigation.pending = nil
        // Task starts on this actor after the flight has been installed.
        // Its lifetime deliberately includes the uncancelable native await.
        let task = Task { @MainActor in
            await self.performSharedNavigation(id: id)
        }
        sharedNavigation.flight = SharedNavigationFlight(
            id: id, generation: generation, input: input, native: native, task: task)
    }

    private func sharedFlightIsCurrent(_ flight: SharedNavigationFlight) -> Bool {
        sharedNavigation.lifecycle == .active && sharedNavigation.isReady &&
            sharedNavigation.flight?.id == flight.id &&
            sharedNavigation.generation == flight.generation &&
            currentSharedNavigationInput == flight.input &&
            currentSharedNavigationNativeIdentity == flight.native
    }

    private func performSharedNavigation(id: UUID) async {
        guard let flight = sharedNavigation.flight, flight.id == id,
              sharedFlightIsCurrent(flight), let publication = viewModel.publication else {
            finishSharedNavigation(id: id, outcome: nil)
            return
        }
        let locator = (try? Locator(jsonString: flight.input.request.position))
            ?? (try? ReaderPositionLocator.decode(jsonString: flight.input.request.position).toReadiumLocator())
        guard let locator else {
            finishSharedNavigation(id: id, outcome: .failed("The controller's reading position is invalid."))
            return
        }
        guard !locator.href.string.isEmpty,
              publication.readingOrder.contains(where: { $0.href == locator.href.string }) else {
            finishSharedNavigation(id: id, outcome: .failed("This shared position is not in the open book."))
            return
        }
        let navigated: Bool
        #if DEBUG
        if let navigation = sharedNavigation.navigationForTesting {
            navigated = await navigation(locator)
        } else {
            navigated = await goToSharedPosition(locator)
        }
        #else
        navigated = await goToSharedPosition(locator)
        #endif
        finishSharedNavigation(id: id, outcome: navigated ? .accepted
            : .failed("The reader could not open the controller's page."))
    }

    private func finishSharedNavigation(id: UUID, outcome: SharedReaderNavigationResult.Outcome?) {
        guard let flight = sharedNavigation.flight, flight.id == id else { return }
        if let outcome, sharedFlightIsCurrent(flight) {
            sharedNavigation.consumed = flight.input
            sharedNavigation.onResult?(SharedReaderNavigationResult(
                revision: flight.input.request.revision, outcome: outcome,
                observedLocator: viewModel.visibleNavigatorLocator))
        }
        // A synchronous callback may replace inputs or retire/reactivate us.
        // Keep the old barrier through that callback and re-read live state.
        guard sharedNavigation.flight?.id == id else { return }
        sharedNavigation.flight = nil
        drainSharedNavigationIfEligible()
    }
}
#endif
