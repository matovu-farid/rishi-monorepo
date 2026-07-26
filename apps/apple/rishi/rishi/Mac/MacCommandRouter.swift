

import SwiftUI
import Observation

@MainActor
@Observable
final class MacCommandRouter {

    private(set) var pendingIntent: MacCommandIntent? = nil


    nonisolated init() {}

 
    func send(_ intent: MacCommandIntent) {
        pendingIntent = intent
    }

    
    func consume() {
        pendingIntent = nil
    }
}




private struct MacCommandRouterKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: MacCommandRouter? = nil
}

extension EnvironmentValues {
    var macCommandRouter: MacCommandRouter? {
        get { self[MacCommandRouterKey.self] }
        set { self[MacCommandRouterKey.self] = newValue }
    }
}
