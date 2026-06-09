// SpikeCAudioEngineApp.swift
// Spike C entry point. SwiftUI App hosting the StreamingPlayer view.

import SwiftUI

@main
struct SpikeCAudioEngineApp: App {
    var body: some Scene {
        WindowGroup {
            StreamingPlayer()
        }
    }
}
