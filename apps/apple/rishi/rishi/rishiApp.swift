//
//  rishiApp.swift
//  rishi
//
//  Created by Farid Matovu on 09/06/2026.
//

import SwiftUI
import SwiftData
import RishiCore
import RishiAuth

@main
struct rishiApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var deps = AppDependencies()

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.rishiAuthService, deps.authServiceForEnvironment)
        }
        .modelContainer(sharedModelContainer)
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        NavigationStack {
            VStack(spacing: 20) {
                Text("Rishi (Debug)")
                    .font(.largeTitle)
                NavigationLink("Open Debug Auth View", destination: DebugAuthView())
                Divider()
                NavigationLink("Scaffold (Items)", destination: ContentView())
            }
            .padding()
        }
        #else
        ContentView()
        #endif
    }
}
