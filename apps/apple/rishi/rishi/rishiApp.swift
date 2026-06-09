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
import RishiLibrary

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
            RootView()
                .environment(\.rishiAuthService, deps.authServiceForEnvironment)
                .environment(deps.libraryViewModel)
                .environment(\.appDependencies, deps)
        }
        .modelContainer(sharedModelContainer)
    }
}
