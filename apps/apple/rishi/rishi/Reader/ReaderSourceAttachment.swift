import SwiftUI
import ReadiumShared

/// One destination's reader-owned work. Stored VM callbacks and cleanup actions
/// use weak attachment ownership; individual bindings keep decisions live.
@MainActor
final class ReaderSourceAttachment {
    struct NavigationState {
        var readAloud: Binding<ReadAloudController?>
        var readerTour: Binding<ReaderOnboardingTourCoordinator?>
        var isFollowingController: Binding<Bool>
        var controlsLocked: Binding<Bool>
        var navigationRevision: Binding<UInt64>
        var navigationEffects: Binding<[UInt64: SharedReadingEffect]>
        var navigationRequest: Binding<SharedReaderNavigationRequest?>
    }

    let id = UUID()
    private let viewModel: ReaderViewModel
    private let sourceLease: BookSourceLease
    private let cleanup: ReaderSourceInvalidationCleanup
    private let playbackOwner: ReadAloudPlaybackOwner
    private let voiceEntry: ReaderVoiceEntry
    private let commit: ReaderPositionSyncBinding.Commit?
    private let syncEngine: SyncEngine
    private let scopedMutationStore: BookScopedMutationStore
    private var cleanupToken: ReaderSourceInvalidationCleanup.Token?
    private var binding: ReaderPositionSyncBinding?
    private var closingTask: Task<ReaderPositionFlushResult, Never>?
    private var closedResult: ReaderPositionFlushResult?
    private(set) var isDisposed = false

    init(
        viewModel: ReaderViewModel,
        sourceLease: BookSourceLease,
        syncEngine: SyncEngine,
        playbackOwner: ReadAloudPlaybackOwner,
        voiceEntry: ReaderVoiceEntry,
        cleanup: ReaderSourceInvalidationCleanup,
        scopedMutationStore: BookScopedMutationStore,
        commit: ReaderPositionSyncBinding.Commit? = nil
    ) {
        self.viewModel = viewModel
        self.sourceLease = sourceLease
        self.playbackOwner = playbackOwner
        self.voiceEntry = voiceEntry
        self.cleanup = cleanup
        self.syncEngine = syncEngine
        self.scopedMutationStore = scopedMutationStore
        self.commit = commit
        installPositionBinding()
    }

    /// Register before attachment setup can suspend (notably PDF backfill).
    /// Completed invalidation is handled inline, never by an untracked task.
    func registerCleanup() async {
        guard !isDisposed, cleanupToken == nil else { return }
        guard !Task.isCancelled else { dispose(); return }
        let action: ReaderSourceInvalidationCleanup.Action = {
            [weak self, viewModel, playbackOwner, voiceEntry] in
            self?.dispose()
            _ = await playbackOwner.stop(reader: viewModel)
            await voiceEntry.endForReader()
        }
        switch cleanup.register(action) {
        case .registered(let token): cleanupToken = token
        case .invalidated: await action()
        case .disposed: dispose()
        }
    }

    /// Called after setup awaits. A departed, invalidated or replaced host
    /// cannot resurrect its binding or navigation callback group.
    @discardableResult
    func installIfCurrent(_ current: ReaderSourceAttachment?, navigation: NavigationState) -> Bool {
        guard current === self, !isDisposed, !Task.isCancelled,
              let admission = try? sourceLease.effectAuthority.admit(sourceLease.sourceAccessPermit)
        else { return false }
        defer { admission.release() }
        if binding == nil { installPositionBinding() }
        viewModel.installNavigationCallbacks(
            owner: id,
            onUserNavigation: { [weak self, weak viewModel] locator in
                guard let self, !self.isDisposed else { return }
                guard !navigation.isFollowingController.wrappedValue && !navigation.controlsLocked.wrappedValue else {
                    let previousRevision = navigation.navigationRevision.wrappedValue
                    navigation.navigationRevision.wrappedValue &+= 1
                    if let effect = navigation.navigationEffects.wrappedValue.removeValue(forKey: previousRevision) {
                        navigation.navigationEffects.wrappedValue[navigation.navigationRevision.wrappedValue] = effect
                    }
                    if let position = navigation.navigationRequest.wrappedValue?.position {
                        navigation.navigationRequest.wrappedValue = SharedReaderNavigationRequest(
                            revision: navigation.navigationRevision.wrappedValue, position: position
                        )
                    }
                    return
                }
                guard let readAloud = navigation.readAloud.wrappedValue else { return }
                readAloud.invalidateReadAloudPositionUpdates()
                Task { @MainActor [weak viewModel] in
                    guard let viewModel else { return }
                    navigation.readerTour.wrappedValue?.userNavigated()
                    let snapshot = readAloud.beginUserNavigationIntent()
                    let destinationParagraphs = await viewModel.paragraphsForUserNavigationIntent(at: locator)
                    guard let intent = readAloud.resolveUserNavigationIntent(
                        snapshot: snapshot, destinationParagraphs: destinationParagraphs,
                        destinationPage: locator.locations.page
                    ) else { return }
                    switch intent {
                    case .continuePlaying:
                        readAloud.allowReadAloudPositionUpdates()
                    case .stopPlaying:
                        viewModel.clearReadAloudResumeLocator()
                        readAloud.invalidateReadAloudPositionUpdates()
                        await readAloud.stop(preservingPosition: false)
                    }
                }
            },
            onUserNavigationForTTSPagePrefetch: { [weak self, weak viewModel] locator in
                guard let self, !self.isDisposed,
                      let readAloud = navigation.readAloud.wrappedValue,
                      readAloud.canPrefetchPageEntry else { return }
                Task { @MainActor [weak viewModel, weak readAloud] in
                    guard let viewModel,
                          let paragraph = await viewModel.firstParagraphForPageEntryPrefetch(at: locator) else { return }
                    await readAloud?.prefetchFirstParagraph(paragraph)
                }
            },
            onExplicitPageForwardNavigation: { [weak self] locator, id in
                guard let self, !self.isDisposed,
                      !navigation.isFollowingController.wrappedValue,
                      !navigation.controlsLocked.wrappedValue,
                      let readAloud = navigation.readAloud.wrappedValue else { return }
                navigation.readerTour.wrappedValue?.userNavigated()
                _ = readAloud.restartAtExplicitPage(locator, id: id)
            }
        )
        return true
    }

    private func installPositionBinding() {
        if let commit {
            binding = ReaderPositionSyncBinding(viewModel: viewModel, sourceLease: sourceLease, commit: commit)
        } else {
            binding = ReaderPositionSyncBinding(
                viewModel: viewModel, syncEngine: syncEngine,
                sourceLease: sourceLease, scopedMutationStore: scopedMutationStore
            )
        }
    }

    @discardableResult
    func flush() async -> ReaderPositionFlushResult {
        guard !isDisposed else { return .revoked }
        return await viewModel.flush()
    }

    /// Save the viewport promptly, retain the commit binding while playback
    /// teardown emits its terminal narration cursor, then drain that cursor.
    /// Native window close and SwiftUI disappearance share the same boundary.
    @discardableResult
    func close(
        using drain: ReaderPositionLifecycleDrain,
        stop: @escaping @MainActor () async -> Void,
        reportFailure: @escaping @MainActor (ReaderPositionFlushResult) -> Void = { _ in }
    ) async -> ReaderPositionFlushResult {
        if let closingTask { return await closingTask.value }
        guard !isDisposed else { return closedResult ?? .revoked }
        let task = Task { @MainActor [self] in
            let initial = await drain.flush { await self.flush() }
            reportFailure(initial)
            await stop()
            let final = await drain.flush { await self.flush() }
            reportFailure(final)
            dispose()
            return final
        }
        closingTask = task
        let result = await task.value
        closedResult = result
        closingTask = nil
        return result
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        binding?.stop()
        binding = nil
        viewModel.clearNavigationCallbacks(ifOwner: id)
        if let cleanupToken { cleanup.unregister(cleanupToken) }
        cleanupToken = nil
    }
}
