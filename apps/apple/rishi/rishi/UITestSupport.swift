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
import CoreGraphics
import CoreText
import Foundation
import RishiAudio
import RishiAuth
import RishiBilling
import RishiCore
import RishiLibrary
import RishiLogging
import UIKit

/// Namespaces the UI-test launch-flag check + the keychain seed.
enum UITestBypass {

    /// True when the host launched the app with `RISHI_UITEST=1` in the
    /// process environment (set via `XCUIApplication.launchEnvironment`).
    ///
    /// ALSO true in live-voice mode (`RISHI_UITEST_LIVE_VOICE=1`) so the
    /// shared auth / entitlement / book-seed / reader-chrome stubs still
    /// fire — only the VOICE stack diverges (see `isLiveVoiceActive`).
    nonisolated static var isActive: Bool {
        ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1" || isLiveVoiceActive
    }

    /// True when the host launched with `RISHI_UITEST_LIVE_VOICE=1`. In this
    /// mode the app reuses every offline RISHI_UITEST stub (sign-in, pro
    /// entitlement, seeded book, visible reader chrome) BUT runs the REAL
    /// voice stack — real `RealtimeAPIAdapter` + real `EphemeralKeyFetcher`
    /// against the live worker/OpenAI — so the live start->end->start
    /// auto-teardown bug can be reproduced. Opt-in: the live-voice UITest
    /// skips unless `DEV_BYPASS_SECRET` is also provided.
    nonisolated static var isLiveVoiceActive: Bool {
        ProcessInfo.processInfo.environment["RISHI_UITEST_LIVE_VOICE"] == "1"
    }

    /// The dev-bypass secret forwarded from the test process. The worker's
    /// `requireAuth` compares `X-Dev-Bypass` timing-safe against its env
    /// `DEV_BYPASS_SECRET`; in live-voice mode this value is attached to
    /// outbound worker requests so the realtime client-secret call succeeds
    /// as `dev-user` with no real session.
    nonisolated static var devBypassSecret: String? {
        ProcessInfo.processInfo.environment["DEV_BYPASS_SECRET"]
    }

    /// Opt-in (RISHI_UITEST_TTS_LATENT=1): wrap the fixture TTS source in a real
    /// CachingTTSChunkSource and add a per-request synthesis DELAY, so the
    /// prewarm-vs-replay timing of the production network path is reproduced.
    /// The default instant fixture path (no caching, no delay) is unchanged, so
    /// existing read-aloud UITests are unaffected.
    nonisolated static var latentCachedTTS: Bool {
        ProcessInfo.processInfo.environment["RISHI_UITEST_TTS_LATENT"] == "1"
    }

    /// Simulated per-paragraph synthesis latency for the latent fixture path.
    /// Below the fixture audio duration (~2.3s) so auto-advance still gets the
    /// next paragraph prewarmed in time, while early/rapid Next presses outrun
    /// the prewarm and exercise the cancel + re-synthesis path.
    nonisolated static var ttsSynthDelay: Duration { .milliseconds(1500) }

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

    /// Simulated synthesis latency emitted BEFORE the first chunk, so the
    /// fixture mimics a network TTS round-trip. Zero by default (instant).
    private let synthDelay: Duration

    init(synthDelay: Duration = .zero) {
        self.synthDelay = synthDelay
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
        let delay = synthDelay
        return AsyncThrowingStream { continuation in
            guard !bytes.isEmpty else {
                continuation.finish()
                return
            }
            let task = Task {
                // Simulated synthesis latency — cancellable, so a prewarm drain
                // that is cancelled mid-synthesis aborts here (mirroring a
                // cancelled network synthesis).
                if delay > .zero {
                    do { try await Task.sleep(for: delay) }
                    catch { continuation.finish(throwing: CancellationError()); return }
                }
                // Split into ~4 chunks so the decoder + player node see a multi
                // buffer feed, mirroring the real streamed shape.
                let chunkCount = 4
                let chunkSize = max(1, bytes.count / chunkCount)
                var offset = 0
                while offset < bytes.count {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let end = min(offset + chunkSize, bytes.count)
                    continuation.yield(bytes.subdata(in: offset..<end))
                    offset = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// DEBUG/UI-test only: generates a TEXT-DENSE multi-page PDF and installs it
/// into the library. The seeded `sample.pdf` is a 3-page tour with one or two
/// short paragraphs per page — far too light to stress the read-aloud
/// page-boundary path. Real books (e.g. Velleman's "How to Prove It") have
/// text-dense pages whose off-main `selectionsByLine` extraction is slow enough
/// to race the main-thread PDFView and return empty text, halting read-aloud at
/// the boundary. We cannot ship that copyrighted book in the app bundle, so we
/// synthesize a comparably dense PDF to reproduce the same race in E2E.
enum UITestDensePDF {

    static let defaultsKey = "rishi.uitestDensePdfInstalled"
    /// Imported book title (filename-derived). The page-boundary UITest selects
    /// the library cell whose label contains "dense".
    static let title = "uitest-dense"

    /// Match how-to-prove-it's small, text-dense page geometry.
    private static let pageSize = CGSize(width: 235, height: 393)
    private static let pageCount = 8

    static func installIfNeeded(storage: BookFileStorage, ownerId: UserID) async {
        guard UITestBypass.isActive else { return }
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        guard let url = generate() else {
            Log.event("uitest.densepdf.generate_failed", level: .error)
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await storage.importBook(from: url, ownerId: ownerId)
            UserDefaults.standard.set(true, forKey: defaultsKey)
            Log.event("uitest.densepdf.installed", level: .info)
        } catch {
            Log.error("uitest.densepdf.install_failed", error: error)
        }
    }

    /// Writes a dense multi-page PDF to a temp file named `uitest-dense.pdf`.
    private static func generate() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title).pdf")
        try? FileManager.default.removeItem(at: url)
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return nil }
        for p in 0..<pageCount {
            ctx.beginPDFPage(nil)
            drawDensePage(ctx, marker: p)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private static func drawDensePage(_ ctx: CGContext, marker: Int) {
        let fontSize: CGFloat = 8
        let lineHeight: CGFloat = 11
        let left: CGFloat = 16
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var y = pageSize.height - 22
        var line = 0
        // Many tight lines, with a larger gap every 5 lines so the layout-aware
        // extractor recovers several paragraphs per page (mirroring a real body
        // page) and the per-page extraction is non-trivial.
        while y > 16 {
            let text = "Page \(marker + 1) line \(line): the quick brown fox jumps over the lazy dog by the quiet riverbank at dawn."
            let attr = NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
            )
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: left, y: y)
            CTLineDraw(ctLine, ctx)
            line += 1
            y -= (line % 5 == 0) ? lineHeight * 2 : lineHeight
        }
    }
}
#endif
