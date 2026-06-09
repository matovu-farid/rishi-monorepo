// SpikeBRealtimeApp.swift
// Spike B entry point. SwiftUI App hosting the RealtimeHarness.

import SwiftUI

@main
struct SpikeBRealtimeApp: App {
    var body: some Scene {
        WindowGroup {
            RealtimeHarness()
        }
    }
}
