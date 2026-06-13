//
//  MacCommandRouter.swift
//  rishi
//
//  Phase 12 Plan 12-01 — @Observable router that the WindowGroup `.commands`
//  block writes into and that `RootView` observes via SwiftUI environment.
//  UI consumes via `.task(id: router.pendingIntent)` and then calls
//  `router.consume()` to clear the slot.
//
//  Coalesce semantics: there is no queue. The latest intent wins because
//  any menu/⌘ tap that arrives before SwiftUI has had a chance to react is
//  user-driven repetition and should not stack. Tests pin this behaviour.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class MacCommandRouter {

    private(set) var pendingIntent: MacCommandIntent? = nil

    /// `nonisolated` so the `AppDependencies` composition root can hold
    /// this as a `let` property whose initializer runs from the
    /// nonisolated `AppDependencies.init()`. Body is empty.
    nonisolated init() {}

    /// Replace the current pending intent. UI is expected to consume the
    /// slot via the SwiftUI environment + `.task(id:)` modifier.
    func send(_ intent: MacCommandIntent) {
        pendingIntent = intent
    }

    /// Clear the slot. Called by UI after the intent has been dispatched.
    func consume() {
        pendingIntent = nil
    }
}

// SwiftUI environment key so non-root views (e.g. inline keyboard shortcuts
// on a toolbar button) can also fire intents without dragging
// `AppDependencies` into their scope.
private struct MacCommandRouterKey: EnvironmentKey {
    @MainActor static let defaultValue: MacCommandRouter? = nil
}

extension EnvironmentValues {
    var macCommandRouter: MacCommandRouter? {
        get { self[MacCommandRouterKey.self] }
        set { self[MacCommandRouterKey.self] = newValue }
    }
}
