import Foundation
import Testing
@testable import rishi

#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import AudioToolbox

@Suite("Chunked audio player TTS engine", .serialized)
struct ChunkedAudioPlayerTTSEngineTests {
    @Test("synchronous native start then finish always completes successfully")
    @MainActor
    func synchronousCallbacksStayOrdered() async throws {
        let factory = ControlledNativePlayerFactory(behavior: .startAndFinish)
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory)
        // Exercise the production actor hops repeatedly; the native callback
        // order is fixed regardless of when the actor consumer gets scheduled.
        for _ in 0..<100 {
            await engine.start(request: request())
            try await engine.waitUntilFinished()
            #expect(state.status == .stopped)
            #expect(state.userFacingFailure == nil)
        }
        await engine.stop()
    }

    @Test("finish without native start remains a playback failure")
    @MainActor
    func finishWithoutStartStillFails() async {
        let factory = ControlledNativePlayerFactory(behavior: .finishOnly)
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory)
        await engine.start(request: request())
        await #expect(throws: TTSEnginePlaybackError.finishedWithoutPlaying) {
            try await engine.waitUntilFinished()
        }
        #expect(state.status != .playing)
        await engine.stop()
    }

    @Test("completion before the waiter is retained once")
    @MainActor
    func completionBeforeWaiterIsRetained() async throws {
        let factory = ControlledNativePlayerFactory(behavior: .startAndFinish)
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory)
        await engine.start(request: request())
        await waitForStatus(.stopped, state: state)
        try await engine.waitUntilFinished()
        // The result was consumed. A second waiter must be cancelled by stop,
        // rather than completing from the same native finish a second time.
        let waiter = Task { try await engine.waitUntilFinished() }
        await engine.stop()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test("late and duplicate callbacks cannot change a replacement request")
    @MainActor
    func staleCallbacksCannotSettleReplacement() async throws {
        let factory = ControlledNativePlayerFactory(behavior: .manual)
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory)
        await engine.start(request: request())
        let oldPlayer = factory.players[0]
        oldPlayer.emitStart()
        await waitForStatus(.playing, state: state)
        await engine.stop()

        let replacementRequest = request()
        await engine.start(request: replacementRequest)
        oldPlayer.emitFinish()
        oldPlayer.emitStart()
        oldPlayer.emitFinish()
        let replacement = factory.players[1]
        replacement.emitStart()
        replacement.emitStart()
        replacement.emitFinish()
        replacement.emitFinish()
        try await engine.waitUntilFinished()
        #expect(state.activeTokenSnapshot == replacementRequest.tokenSnapshot)
        #expect(state.status == .stopped)
        #expect(state.userFacingFailure == nil)
        await engine.stop()
    }

    @Test("stop cancels an active waiter and rejects callbacks from the stopped player")
    @MainActor
    func stopCancelsWaiter() async {
        let factory = ControlledNativePlayerFactory(behavior: .manual)
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory)
        await engine.start(request: request())
        let nativePlayer = factory.players[0]
        nativePlayer.emitStart()
        await waitForStatus(.playing, state: state)
        let waiter = Task { try await engine.waitUntilFinished() }
        await engine.stop()
        nativePlayer.emitFinish()
        nativePlayer.emitStart()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(nativePlayer.stopCount == 1)
    }

    @Test("native failure cannot be replaced by a later start or successful finish")
    @MainActor
    func terminalFailureRejectsDuplicates() async {
        let factory = ControlledNativePlayerFactory(behavior: .manual)
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory)
        await engine.start(request: request())
        let nativePlayer = factory.players[0]
        nativePlayer.fail(message: "decoder failed")
        await #expect(throws: TTSEnginePlaybackError.playbackFailed("decoder failed")) {
            try await engine.waitUntilFinished()
        }
        nativePlayer.emitStart()
        nativePlayer.emitFinish()
        #expect(state.status == .error)
        #expect(state.userFacingFailure == .audioPlayback)
        await engine.stop()
    }

    @Test("original source errors survive native termination before and after waiting", arguments: NativeSourceFailureCase.allCases, [false, true])
    @MainActor
    func sourceFailureSurvivesNativeTermination(kind: NativeSourceFailureCase, finishBeforeWait: Bool) async {
        let original = kind.error
        let source = GatedNativeSource()
        let factory = ControlledNativePlayerFactory(behavior: .consumeStream)
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory, source: source)
        let activeRequest = request()
        await engine.start(request: activeRequest)
        await source.waitForRequestCount(1)
        await source.yieldFirstChunk()
        await waitForStatus(.playing, state: state)
        var failure: Error?
        if finishBeforeWait {
            await source.finish(error: original)
            await waitForStatus(kind.category == nil ? .stopped : .error, state: state)
            do { try await engine.waitUntilFinished() } catch { failure = error }
        } else {
            let waiter = Task { try await engine.waitUntilFinished() }
            await source.finish(error: original)
            do { try await waiter.value } catch { failure = error }
        }
        if let failure {
            #expect(String(reflecting: type(of: failure)) == String(reflecting: type(of: original)))
            #expect((failure as NSError).domain == (original as NSError).domain)
            #expect((failure as NSError).code == (original as NSError).code)
            #expect(TTSUserFacingError.classify(failure) == kind.category)
        } else { Issue.record("Expected the original source error, got success") }
        #expect(state.activeTokenSnapshot == activeRequest.tokenSnapshot)
        #expect(state.userFacingFailure == kind.category)
        #expect(state.status == (kind.category == nil ? .stopped : .error))
        if kind == .allowance {
            #expect(state.typedFailure == .narration(message: "source allowance"))
            #expect(state.typedFailureTokens == activeRequest.tokenSnapshot)
        }
        await engine.stop()
    }

    @Test("a new request clears the previous source failure before a native failure")
    @MainActor
    func sourceFailureResetsForNextRequest() async {
        let source = GatedNativeSource()
        let factory = ControlledNativePlayerFactory(behaviors: [.consumeStream, .manual])
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory, source: source)
        await engine.start(request: request())
        await source.waitForRequestCount(1)
        await source.finish(error: URLError(.networkConnectionLost))
        do { try await engine.waitUntilFinished() } catch {}
        let replacement = request()
        await engine.start(request: replacement)
        await source.waitForRequestCount(2)
        factory.players[1].fail(message: "replacement decoder failed")
        await #expect(throws: TTSEnginePlaybackError.playbackFailed("replacement decoder failed")) {
            try await engine.waitUntilFinished()
        }
        #expect(state.activeTokenSnapshot == replacement.tokenSnapshot)
        #expect(state.userFacingFailure == .audioPlayback)
        await engine.stop()
    }

    @Test("late stopped source and native failures cannot mutate a replacement")
    @MainActor
    func stoppedSourceFailureCannotContaminateReplacement() async throws {
        let source = GatedNativeSource()
        let factory = ControlledNativePlayerFactory(behaviors: [.consumeStream, .manual])
        let state = TTSPlaybackState()
        let engine = makeEngine(state: state, factory: factory, source: source)
        await engine.start(request: request())
        await source.waitForRequestCount(1)
        let oldPlayer = factory.players[0]
        await engine.stop()
        let replacement = request()
        await engine.start(request: replacement)
        await source.waitForRequestCount(2)
        await source.finish(error: RishiError.unauthenticated, requestIndex: 0)
        oldPlayer.fail(message: "late old decoder failed")
        factory.players[1].emitStart()
        await waitForStatus(.playing, state: state)
        #expect(state.activeTokenSnapshot == replacement.tokenSnapshot)
        #expect(state.userFacingFailure == nil)
        factory.players[1].emitFinish()
        try await engine.waitUntilFinished()
        #expect(state.userFacingFailure == nil)
        await engine.stop()
    }

    @MainActor
    private func makeEngine(
        state: TTSPlaybackState,
        factory: ControlledNativePlayerFactory,
        source: any TTSChunkSource = EmptyAudioSource()
    ) -> ChunkedAudioPlayerTTSEngine {
        ChunkedAudioPlayerTTSEngine(
            streamer: TTSStreamer(source: source),
            state: state,
            playerFactory: { factory.make(didStart: $0, didFinish: $1) }
        )
    }

    private func request() -> TTSStreamRequest {
        TTSStreamRequest(text: "callback ordering", voice: "alloy", speed: 1.0)
    }

    @MainActor
    private func waitForStatus(_ expected: TTSStatus, state: TTSPlaybackState) async {
        let deadline = Date().addingTimeInterval(2)
        while state.status != expected && Date() < deadline {
            await Task.yield()
        }
        #expect(state.status == expected)
    }

    @Test("typed allowance failure is recorded before player failure can become stopped")
    @MainActor
    func typedAllowanceFailureIsSticky() async {
        let state = TTSPlaybackState()
        let streamer = TTSStreamer(source: TypedAllowanceSource())
        let engine = ChunkedAudioPlayerTTSEngine(streamer: streamer, state: state)
        let request = TTSStreamRequest(
            text: "allowance",
            voice: "alloy",
            speed: 1.0,
            sessionToken: UUID(),
            utteranceToken: UUID(),
            requestToken: UUID()
        )

        await engine.start(request: request)
        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(state.typedFailure == .narration(message: "narration exhausted"))
        #expect(state.typedFailureTokens == request.tokenSnapshot)
        #expect(state.userFacingFailure == .narrationExhausted)
        #expect(state.status == .error)
        await engine.stop()
    }
}

private struct EmptyAudioSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// The fake controls only native callback delivery; the real engine owns event
/// consumption, token fences, state publication, and completion continuations.
private final class ControlledNativePlayerFactory: @unchecked Sendable {
    enum Behavior: Sendable { case manual, startAndFinish, finishOnly, consumeStream }
    private let lock = NSLock()
    private var behaviors: [Behavior]
    private var storage: [ControlledNativePlayer] = []

    init(behavior: Behavior) { self.behaviors = [behavior] }
    init(behaviors: [Behavior]) { self.behaviors = behaviors }
    var players: [ControlledNativePlayer] { lock.withLock { storage } }

    func make(
        didStart: @escaping @Sendable () -> Void,
        didFinish: @escaping @Sendable () -> Void
    ) -> ControlledNativePlayer {
        let behavior = lock.withLock {
            behaviors.count > 1 ? behaviors.removeFirst() : behaviors[0]
        }
        let player = ControlledNativePlayer(
            behavior: behavior, didStart: didStart, didFinish: didFinish
        )
        lock.withLock { storage.append(player) }
        return player
    }
}

private final class ControlledNativePlayer: ChunkedTTSNativePlayer, @unchecked Sendable {
    private let lock = NSLock()
    private let behavior: ControlledNativePlayerFactory.Behavior
    private let didStart: @Sendable () -> Void
    private let didFinish: @Sendable () -> Void
    private var failureStorage: ChunkedTTSNativePlayerFailure?
    private var stops = 0
    private var consumer: Task<Void, Never>?

    init(
        behavior: ControlledNativePlayerFactory.Behavior,
        didStart: @escaping @Sendable () -> Void,
        didFinish: @escaping @Sendable () -> Void
    ) {
        self.behavior = behavior
        self.didStart = didStart
        self.didFinish = didFinish
    }

    func start(_ stream: AsyncThrowingStream<Data, Error>) {
        switch behavior {
        case .manual: break
        case .startAndFinish:
            didStart()
            didFinish()
        case .finishOnly: didFinish()
        case .consumeStream:
            let task = Task { [self] in
                var started = false
                do {
                    for try await _ in stream {
                        if !started { started = true; didStart() }
                    }
                    if !Task.isCancelled { didFinish() }
                } catch {
                    guard !Task.isCancelled else { return }
                    // Native decoding reports only a generic failure. The real
                    // engine must retain the upstream Error before this callback.
                    fail(message: "native stream rejected")
                }
            }
            lock.withLock { consumer = task }
        }
    }
    func pause() {}
    func resume() {}
    func stop() {
        let task = lock.withLock { stops += 1; return consumer }
        task?.cancel()
    }
    var stopCount: Int { lock.withLock { stops } }
    @MainActor var failure: ChunkedTTSNativePlayerFailure? {
        lock.withLock { failureStorage }
    }
    func emitStart() { didStart() }
    func emitFinish() { didFinish() }
    func fail(message: String) {
        lock.withLock { failureStorage = ChunkedTTSNativePlayerFailure(message: message) }
        didFinish()
    }
}

private struct TypedAllowanceSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: WorkerAllowanceError.narration(message: "narration exhausted"))
        }
    }
}
private enum NativeSourceFailureCase: Sendable, CaseIterable {
    case network, rawURL, service, authentication, consent, allowance, cancellation, urlCancellation, wrappedCancellation
    var error: Error {
        switch self {
        case .network: RishiError.networkFailure(URLError(.notConnectedToInternet))
        case .rawURL: URLError(.networkConnectionLost)
        case .service: RishiError.network(code: "http_503", message: "private source detail")
        case .authentication: RishiError.unauthenticated
        case .consent: WorkerDataUseConsentRequiredError()
        case .allowance: WorkerAllowanceError.narration(message: "source allowance")
        case .cancellation: CancellationError()
        case .urlCancellation: URLError(.cancelled)
        case .wrappedCancellation: RishiError.networkFailure(URLError(.cancelled))
        }
    }
    var category: TTSUserFacingError? {
        switch self {
        case .network, .rawURL: .network
        case .service: .serviceUnavailable
        case .authentication: .authentication
        case .consent: .dataUseConsent
        case .allowance: .narrationExhausted
        case .cancellation, .urlCancellation, .wrappedCancellation: nil
        }
    }
}

private actor GatedNativeSource: TTSChunkSource {
    private var requests: [TTSStreamRequest] = []
    private var continuations: [AsyncThrowingStream<TTSChunk, Error>.Continuation] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        let pair = AsyncThrowingStream<TTSChunk, Error>.makeStream()
        requests.append(request)
        continuations.append(pair.continuation)
        let ready = requestWaiters.filter { $0.0 <= requests.count }
        requestWaiters.removeAll { $0.0 <= requests.count }
        for (_, continuation) in ready { continuation.resume() }
        return pair.stream
    }
    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
    func yieldFirstChunk() {
        let request = requests[requests.count - 1]
        continuations[continuations.count - 1].yield(TTSChunk.make(request: request, sequenceIndex: 0, data: Data([1])))
    }
    func finish(error: Error, requestIndex: Int? = nil) {
        continuations[requestIndex ?? (continuations.count - 1)].finish(throwing: error)
    }
}
#endif
