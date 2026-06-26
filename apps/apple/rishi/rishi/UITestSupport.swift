
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


enum UITestBypass {


    nonisolated static var isActive: Bool {
        ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1" || isLiveVoiceActive
    }


    nonisolated static var isLiveVoiceActive: Bool {
        ProcessInfo.processInfo.environment["RISHI_UITEST_LIVE_VOICE"] == "1"
    }


    
    nonisolated static var devBypassSecret: String? {
        ProcessInfo.processInfo.environment["DEV_BYPASS_SECRET"]
    }


    nonisolated static var latentCachedTTS: Bool {
        ProcessInfo.processInfo.environment["RISHI_UITEST_TTS_LATENT"] == "1"
    }

    

    nonisolated static var ttsSynthDelay: Duration { .milliseconds(1500) }


    static let fakeUserIdString = "00000000-0000-0000-0000-000000000001"


    nonisolated static func seedProEntitlementIfNeeded() {
        guard isActive else { return }
        UserDefaults.standard.set(
            EntitlementLevel.subscribed.rawValue,
            forKey: EntitlementService.defaultsKey
        )
        
        
        
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        Log.event("uitest.entitlement.seeded_pro", level: .info)
    }

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


struct FixtureTTSChunkSource: TTSChunkSource {


    private let data: Data


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
                
                
                
                if delay > .zero {
                    do { try await Task.sleep(for: delay) }
                    catch { continuation.finish(throwing: CancellationError()); return }
                }
                
                
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


enum UITestDensePDF {

    static let defaultsKey = "rishi.uitestDensePdfInstalled"

    static let title = "uitest-dense"

    
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
