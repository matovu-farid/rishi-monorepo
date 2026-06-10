//
//  RootView.swift
//  rishi
//
//  Phase 4 Plan 04-06 — top-level view gating Library vs DebugAuth on the
//  current authenticated user.
//  Phase 5 Plan 05-07 — presents PDFReaderScreen as a full-screen cover
//  when the user taps a .pdf book in the library; .epub books route to
//  an explicit placeholder until Phase 6.
//
//  The reader is mounted as a full-screen cover (not a navigationDestination)
//  because LibraryRootView owns its own NavigationStack. Nesting another
//  NavigationStack causes split-view weirdness on iPad / Catalyst.
//

import SwiftUI
import RishiCore
import RishiAuth
import RishiLibrary
import RishiReader

struct RootView: View {

    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps
    @Environment(LibraryViewModel.self) private var libraryViewModel

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    /// Non-nil while the reader (or EPUB placeholder) is presented.
    @State private var openTarget: OpenTarget?

    var body: some View {
        Group {
            if let user = currentUser, let deps = deps {
                LibraryRootView(importCoordinator: deps.importCoordinator) { book in
                    openTarget = openTarget(for: book)
                }
                .task(id: user.id) {
                    deps.cachedUserId = user.id
                    _ = await deps.sampleBookInstaller.installIfNeeded(ownerId: user.id)
                    _ = await deps.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
                    await libraryViewModel.refresh()
                }
                #if canImport(UIKit)
                .fullScreenCover(item: $openTarget) { target in
                    destinationView(for: target, deps: deps, userId: user.id)
                }
                #else
                .sheet(item: $openTarget) { target in
                    destinationView(for: target, deps: deps, userId: user.id)
                }
                #endif
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

    // MARK: - Navigation destinations

    private func openTarget(for book: Book) -> OpenTarget {
        switch book.formatType {
        case .pdf:                  return .pdf(book)
        case .epub, .mobi, .azw3:   return .epubPlaceholder(book)
        }
    }

    @ViewBuilder
    private func destinationView(for target: OpenTarget,
                                 deps: AppDependencies,
                                 userId: UserID) -> some View {
        switch target {
        case .pdf(let book):
            PDFReaderScreen(
                viewModel: PDFReaderViewModel(
                    book: book,
                    userId: userId,
                    documentURL: pdfFileURL(for: book),
                    positionStore: deps.positionStore
                ),
                readerSettingsStore: deps.readerSettingsStore,
                highlightStore: deps.highlightStore
            )
        case .epubPlaceholder(let book):
            EpubPlaceholderView(book: book) {
                openTarget = nil
            }
        }
    }

    private func pdfFileURL(for book: Book) -> URL {
        // `BookFileStorage` is an actor, but its file-URL computation is a
        // pure path concat that only reads the configured root URL. We
        // recompute the same thing here using the Documents directory so
        // we don't need to await across the actor boundary at view-build
        // time.
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return documentsURL.appendingPathComponent(book.fileURL)
    }

    @ViewBuilder private var signedOutView: some View {
        #if DEBUG
        NavigationStack { DebugAuthView() }
        #else
        VStack {
            Text("Sign in to Rishi to access your library")
                .font(.title2)
                .padding()
        }
        #endif
    }
}

/// Hashable + Identifiable nav target so `fullScreenCover(item:)` can
/// pick the correct destination based on book format.
private enum OpenTarget: Hashable, Identifiable {
    case pdf(Book)
    case epubPlaceholder(Book)

    var id: BookID {
        switch self {
        case .pdf(let book), .epubPlaceholder(let book): return book.id
        }
    }
}

/// Phase 6 will replace this with the real EPUB reader. Shipped here so we
/// never silently no-op when the user taps an .epub.
private struct EpubPlaceholderView: View {
    let book: Book
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                Text(book.title)
                    .font(.title3)
                Text("EPUB reader arrives in Phase 6.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}
