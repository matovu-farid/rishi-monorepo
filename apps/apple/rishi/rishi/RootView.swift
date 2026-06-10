//
//  RootView.swift
//  rishi
//
//  Phase 4 Plan 04-06 — top-level view gating Library vs DebugAuth on the
//  current authenticated user.
//  Phase 5 Plan 05-07 — presents PDFReaderScreen as a full-screen cover
//  when the user taps a .pdf book in the library; .epub books route to
//  an explicit placeholder until Phase 6.
//  Phase 6 Plan 06-06 — .epub now opens EPUBReaderScreen for real;
//  .mobi / .azw3 keep routing to the placeholder until a future phase
//  adds a converter.
//
//  The reader is mounted as a full-screen cover (not a navigationDestination)
//  because LibraryRootView owns its own NavigationStack. Nesting another
//  NavigationStack causes split-view weirdness on iPad / Catalyst.
//

import SwiftUI
import RishiCore
import RishiAudio
import RishiAuth
import RishiLibrary
import RishiReader
#if canImport(PDFKit)
import PDFKit
#endif

struct RootView: View {

    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps
    @Environment(LibraryViewModel.self) private var libraryViewModel

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    /// Non-nil while the reader (or EPUB placeholder) is presented.
    @State private var openTarget: OpenTarget?

    /// Holds the active reader → sync bridge for the lifetime of the open
    /// reader sheet. The bridge polls the VM and forwards position changes
    /// to `SyncEngine.markPositionDirty`. Cleared on dismiss so its task
    /// cancels via `deinit`.
    @State private var pdfSyncBinding: PDFReaderPositionSyncBinding? = nil
    @State private var epubSyncBinding: EPUBReaderPositionSyncBinding? = nil

    /// SYNC-08 — Settings sheet entry point. Presented from the toolbar
    /// gear button below.
    @State private var showSettings = false

    // MARK: - Phase 8 (TTS) state
    //
    // The ReaderTTSBridge is constructed per-reader-sheet by AppDependencies
    // and retained here. Two sheets — the controls and the voice/speed
    // picker — present and dismiss independently.
    @State private var readerTTSBridge: ReaderTTSBridge? = nil
    @State private var showTTSControls = false
    @State private var showTTSPicker = false
    @State private var ttsPickerInitial: TTSSettings = .default

    var body: some View {
        Group {
            if let user = currentUser, let deps = deps {
                LibraryRootView(
                    importCoordinator: deps.importCoordinator,
                    onOpenBook: { book in openTarget = openTarget(for: book) },
                    onShowSettings: { showSettings = true }
                )
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
                .sheet(isPresented: $showSettings) {
                    SettingsSheet(dependencies: deps)
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

    // MARK: - Navigation destinations

    private func openTarget(for book: Book) -> OpenTarget {
        switch book.formatType {
        case .pdf:            return .pdf(book)
        case .epub:           return .epub(book)
        case .mobi, .azw3:    return .unsupportedFormat(book)
        }
    }

    @ViewBuilder
    private func destinationView(for target: OpenTarget,
                                 deps: AppDependencies,
                                 userId: UserID) -> some View {
        switch target {
        case .pdf(let book):
            let pdfVM = PDFReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: deps.positionStore
            )
            PDFReaderScreen(
                viewModel: pdfVM,
                readerSettingsStore: deps.readerSettingsStore,
                highlightStore: deps.highlightStore,
                onReadAloud: FeatureFlags.readAloud ? {
                    Task { await startPDFReadAloud(vm: pdfVM, deps: deps, userId: userId) }
                } : nil
            )
            // SYNC-03 wiring: install a sync bridge for the lifetime of the
            // reader sheet. The binding cancels its poll task on deinit.
            .task {
                pdfSyncBinding = PDFReaderPositionSyncBinding(
                    viewModel: pdfVM,
                    syncEngine: deps.syncEngine
                )
            }
            .onDisappear {
                pdfSyncBinding = nil
                Task { await stopReadAloud() }
            }
            .sheet(isPresented: $showTTSControls) {
                if let bridge = readerTTSBridge {
                    ReadAloudControlsView(
                        state: deps.ttsState,
                        onPlayPause: {
                            Task {
                                if deps.ttsState.status == .playing {
                                    await bridge.pause()
                                } else {
                                    await bridge.resume()
                                }
                            }
                        },
                        onStop: {
                            Task { await stopReadAloud() }
                        },
                        onOpenPicker: {
                            showTTSPicker = true
                        }
                    )
                    .presentationDetents([.height(180), .medium])
                }
            }
            .sheet(isPresented: $showTTSPicker) {
                VoiceAndSpeedPicker(
                    initial: ttsPickerInitial,
                    userId: userId,
                    store: deps.ttsSettingsStore,
                    onDismiss: { settings in
                        ttsPickerInitial = settings
                        showTTSPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        case .epub(let book):
            let epubVM = EPUBReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: deps.positionStore
            )
            EPUBReaderScreen(
                viewModel: epubVM,
                readerSettingsStore: deps.readerSettingsStore,
                highlightStore: deps.highlightStore,
                onReadAloud: FeatureFlags.readAloud ? {
                    Task { await startEPUBReadAloud(vm: epubVM, deps: deps, userId: userId) }
                } : nil
            )
            .task {
                epubSyncBinding = EPUBReaderPositionSyncBinding(
                    viewModel: epubVM,
                    syncEngine: deps.syncEngine
                )
            }
            .onDisappear {
                epubSyncBinding = nil
                Task { await stopReadAloud() }
            }
            .sheet(isPresented: $showTTSControls) {
                if let bridge = readerTTSBridge {
                    ReadAloudControlsView(
                        state: deps.ttsState,
                        onPlayPause: {
                            Task {
                                if deps.ttsState.status == .playing {
                                    await bridge.pause()
                                } else {
                                    await bridge.resume()
                                }
                            }
                        },
                        onStop: {
                            Task { await stopReadAloud() }
                        },
                        onOpenPicker: {
                            showTTSPicker = true
                        }
                    )
                    .presentationDetents([.height(180), .medium])
                }
            }
            .sheet(isPresented: $showTTSPicker) {
                VoiceAndSpeedPicker(
                    initial: ttsPickerInitial,
                    userId: userId,
                    store: deps.ttsSettingsStore,
                    onDismiss: { settings in
                        ttsPickerInitial = settings
                        showTTSPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        case .unsupportedFormat(let book):
            EpubPlaceholderView(book: book) {
                openTarget = nil
            }
        }
    }

    // MARK: - Read Aloud (Phase 8)

    private func startPDFReadAloud(
        vm: PDFReaderViewModel,
        deps: AppDependencies,
        userId: UserID
    ) async {
        #if canImport(PDFKit)
        guard let doc = vm.document else { return }
        let sentences = vm.sentencesForReadAloud(
            document: doc,
            currentPageIndex: vm.pageIndex
        )
        await startReadAloud(
            sentences: sentences,
            deps: deps,
            userId: userId,
            onPassageChange: { index in vm.currentReadAloudPassageIndex = index }
        )
        #endif
    }

    private func startEPUBReadAloud(
        vm: EPUBReaderViewModel,
        deps: AppDependencies,
        userId: UserID
    ) async {
        let sentences = await vm.sentencesForReadAloud()
        await startReadAloud(
            sentences: sentences,
            deps: deps,
            userId: userId,
            onPassageChange: { index in vm.currentReadAloudPassageIndex = index }
        )
    }

    private func startReadAloud(
        sentences: [String],
        deps: AppDependencies,
        userId: UserID,
        onPassageChange: @escaping (Int?) -> Void
    ) async {
        guard !sentences.isEmpty else { return }
        // Tear down any existing bridge before starting a new session.
        if let existing = readerTTSBridge {
            await existing.stop()
        }
        let bridge = deps.makeReaderTTSBridge(
            userId: userId,
            onPassageChange: onPassageChange
        )
        readerTTSBridge = bridge
        ttsPickerInitial = await deps.ttsSettingsStore.load(userId: userId)
        showTTSControls = true
        await bridge.start(sentences: sentences)
    }

    private func stopReadAloud() async {
        if let bridge = readerTTSBridge {
            await bridge.stop()
        }
        readerTTSBridge = nil
        showTTSControls = false
        showTTSPicker = false
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
    case epub(Book)
    case unsupportedFormat(Book)

    var id: BookID {
        switch self {
        case .pdf(let book), .epub(let book), .unsupportedFormat(let book):
            return book.id
        }
    }
}

/// Catches `.mobi` / `.azw3` taps — those formats need a converter step
/// that isn't on the v1 milestone. Shipped here so the library never
/// silently no-ops when the user taps an unsupported book.
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
                Text("MOBI / AZW3 aren't supported yet.")
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
