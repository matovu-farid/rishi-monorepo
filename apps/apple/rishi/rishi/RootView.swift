//
//  RootView.swift
//  rishi
//
//  Phase 4 Plan 04-06 — top-level view gating Library vs DebugAuth on the
//  current authenticated user. Signed in → LibraryRootView (mounts
//  LibraryView), signed out → DebugAuthView (DEBUG) or sign-in CTA (Release).
//

import SwiftUI
import RishiCore
import RishiAuth
import RishiLibrary

struct RootView: View {

    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps
    @Environment(LibraryViewModel.self) private var libraryViewModel

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    var body: some View {
        Group {
            if let user = currentUser, let deps = deps {
                LibraryRootView(importCoordinator: deps.importCoordinator) { book in
                    // Phase 5/6 will replace this with reader navigation.
                    print("Open book: \(book.title)")
                }
                .task(id: user.id) {
                    deps.cachedUserId = user.id
                    _ = await deps.sampleBookInstaller.installIfNeeded(ownerId: user.id)
                    await libraryViewModel.refresh()
                }
            } else {
                signedOutView
            }
        }
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            currentUser = await auth?.currentUser
        }
        .onOpenURL { url in
            guard let deps = deps else { return }
            Task {
                _ = await deps.importCoordinator.importBooks([url])
                await libraryViewModel.refresh()
            }
        }
    }

    @ViewBuilder private var signedOutView: some View {
        #if DEBUG
        NavigationStack { DebugAuthView() }
        #else
        // Production: Phase 11 will replace this with a real onboarding sign-in
        // CTA. For first TestFlight we surface a minimal sign-in prompt.
        VStack {
            Text("Sign in to Rishi to access your library")
                .font(.title2)
                .padding()
        }
        #endif
    }
}
