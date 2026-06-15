//
//  UITestSupport.swift
//  rishi
//
//  DEBUG-only scaffolding that lets an XCUITest drive the app fully offline
//  and signed-out. Everything in this file is gated behind BOTH `#if DEBUG`
//  AND the `RISHI_UITEST == "1"` launch environment variable, so it can never
//  affect a TestFlight / App Store build and never runs in a normal launch.
//
//  Two seams are provided:
//    1. `UITestBypass.seedFakeSessionIfNeeded(into:)` — writes a fixed fake
//       `Session` into the real KeychainSessionStore BEFORE the auth probe
//       runs, so `RishiAuthService.currentUser` resolves a stable test `User`
//       with zero network. `RootView.currentUser` then branches into the
//       library.
//    2. `FixtureTTSChunkSource` — a `TTSChunkSource` that yields the bytes of
//       a bundled MP3 (`uitest-tts.mp3`) in a few chunks for EVERY request, so
//       passage 0 and passage 1 both produce real audio through the real
//       AVAudioEngine. This makes `bridge.next()` a genuine mid-passage switch
//       (the path that exercises `resetPlayerNode()`), with no worker round
//       trip and no auth.
//

#if DEBUG
import Foundation
import RishiAudio
import RishiAuth
import RishiBilling
import RishiCore
import RishiLogging

/// Namespaces the UI-test launch-flag check + the keychain seed.
enum UITestBypass {

    /// True when the host launched the app with `RISHI_UITEST=1` in the
    /// process environment (set via `XCUIApplication.launchEnvironment`).
    nonisolated static var isActive: Bool {
        ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1"
    }

    /// Fixed, deterministic identity so the seeded user is stable across runs.
    /// `RishiAuthService.makeUser(from:)` derives the in-memory `User.id` from
    /// `Session.userId`; we use a UUID-shaped string so that derivation returns
    /// this UUID verbatim.
    static let fakeUserIdString = "00000000-0000-0000-0000-000000000001"

    /// Seeds the `EntitlementService` UserDefaults cache to `.pro` so the
    /// Read Aloud entitlement gate (RootView's `entitlementService.snapshot()`
    /// == .pro check) passes offline — otherwise the offline `refresh()` fails
    /// and `snapshot()` falls back to `.free`, surfacing the paywall instead
    /// of starting playback. Must run BEFORE `EntitlementService.init` (which
    /// hydrates `latest` from this key). No-op unless the UI-test flag is set.
    nonisolated static func seedProEntitlementIfNeeded() {
        guard isActive else { return }
        UserDefaults.standard.set(
            EntitlementLevel.pro.rawValue,
            forKey: EntitlementService.defaultsKey
        )
        // Skip the first-launch onboarding flow so it doesn't overlay the
        // library and block the book tap. Key mirrors
        // UserDefaultsOnboardingState.keyCompleted ("onboarding.completed").
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        Log.event("uitest.entitlement.seeded_pro", level: .info)
    }

    /// Writes a fake `Session` into the keychain store the auth service reads
    /// from. Called from `AppDependencies.buildServices` BEFORE the auth probe
    /// in `RootView`'s bootstrap `.task` runs, so `currentUser` resolves
    /// non-nil offline. No-op unless the UI-test flag is set.
    static func seedFakeSessionIfNeeded(into keychain: KeychainSessionStore) async {
        guard isActive else { return }
        let session = Session(
            token: "uitest-fake-token",
            userId: fakeUserIdString,
            email: "uitest@rishi.local",
            provider: .apple,
            issuedAt: Date(),
            expiresAt: nil
        )
        do {
            try await keychain.save(session)
            Log.event("uitest.auth.seeded", level: .info, data: [
                "userId": fakeUserIdString,
            ])
        } catch {
            Log.error("uitest.auth.seed_failed", error: error)
        }
    }
}

/// Deterministic offline `TTSChunkSource`. Loads a bundled MP3 once and yields
/// it back in a handful of chunks for EVERY request, so each passage switch
/// renders real audio through the production AVAudioEngine path without any
/// network or auth. Used only when `RISHI_UITEST=1`.
struct FixtureTTSChunkSource: TTSChunkSource {

    /// Bundled fixture bytes, loaded eagerly at construction. If the resource
    /// is missing we fall back to empty data (the stream still completes, the
    /// test will surface the misconfiguration as a stuck/empty playback).
    private let data: Data

    init() {
        if let url = Bundle.main.url(forResource: "uitest-tts", withExtension: "mp3"),
           let loaded = try? Data(contentsOf: url) {
            self.data = loaded
            Log.event("uitest.tts.fixture.loaded", level: .info, data: [
                "bytes": String(loaded.count),
            ])
        } else {
            self.data = Data()
            Log.event("uitest.tts.fixture.missing", level: .error)
        }
    }

    func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
        let bytes = data
        return AsyncThrowingStream { continuation in
            guard !bytes.isEmpty else {
                continuation.finish()
                return
            }
            // Split into ~4 chunks so the decoder + player node see a multi
            // buffer feed, mirroring the real streamed shape.
            let chunkCount = 4
            let chunkSize = max(1, bytes.count / chunkCount)
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunkSize, bytes.count)
                continuation.yield(bytes.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }
}
#endif
