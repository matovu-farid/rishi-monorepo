@testable import rishi
import Testing
import Foundation



/// OPT-IN, env-gated real TTS->STT round-trip (RESEARCH §5.1/§5.2/§5.4).
///
/// This suite is the phase's headline acceptance test: it drives the REAL worker
/// `/api/audio/speech` route via `WorkerTTSChunkSource`, collects the streamed MP3
/// bytes, POSTs them to the REAL worker `/api/audio/transcribe` route (Deepgram,
/// JSON `{audio: <base64>, mime_type: "audio/mpeg"}`), and fuzzy-asserts the
/// transcript matches the source text via `TokenOverlap` (threshold 0.6).
///
/// It is fully SKIPPED in the default/CI lane via `.enabled(if:)` — it never runs,
/// and makes no network call, unless `RISHI_TTS_E2E=1` is set. The deterministic
/// offline sibling (`TTSRoundTripOfflineTests`) is the default-lane coverage.
///
/// Required environment to run a live round-trip:
///   - `RISHI_TTS_E2E=1`              enables the suite
///   - `RISHI_WORKER_URL=https://...` base URL of the deployed worker
///   - `RISHI_DEV_BYPASS=<secret>`    value the worker compares against
///     `DEV_BYPASS_SECRET` via `timingSafeEqual` (see workers/worker/src/index.ts
///     requireAuth). RESEARCH Open Q1: the worker does NOT accept the literal "1"
///     unless `DEV_BYPASS_SECRET` itself is "1" — it must MATCH the deployed secret.
///     If unset, the test falls back to `WorkerClient(devBypassEnabled: true)`
///     which sends "1"; supply a real session via `RISHI_WORKER_TOKEN` instead if
///     the deployment's secret differs.
///   - `RISHI_WORKER_TOKEN=<jwt>`     (optional) Bearer token if not using bypass.
@Suite(
    "TTS round-trip (network)",
    .enabled(if: ProcessInfo.processInfo.environment["RISHI_TTS_E2E"] == "1"),
    .serialized
)
struct TTSRoundTripNetworkTests {

    private struct TranscribeResponse: Decodable { let transcript: String }

    private func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    private func loadExpectedText() throws -> String {
        let url = try #require(
            PackageTestResourceBundle.bundle.url(forResource: "alice-p0-expected", withExtension: "txt", subdirectory: "Fixtures"),
            "alice-p0-expected.txt ground-truth fixture must be bundled"
        )
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("real TTS audio transcribes back to the source text (token-overlap >= 0.6)")
    func liveRoundTrip() async throws {
        // 1. Worker base URL is mandatory in an enabled run — never hard-code prod.
        let urlString = try #require(
            env("RISHI_WORKER_URL"),
            "RISHI_TTS_E2E is set but RISHI_WORKER_URL is missing; set it to the deployed worker base URL"
        )
        let baseURL = try #require(URL(string: urlString), "RISHI_WORKER_URL is not a valid URL: \(urlString)")

        let devBypass = env("RISHI_DEV_BYPASS")
        let bearer = env("RISHI_WORKER_TOKEN")

        // 2. Build the WorkerClient. Prefer an explicit Bearer token if supplied;
        //    otherwise fall back to dev-bypass ("1" via WorkerClient, see caveat above).
        let tokenProvider = StaticTokenProvider(bearer)
        let client = WorkerClient(
            baseURL: baseURL,
            session: .shared,
            tokenProvider: tokenProvider,
            devBypassEnabled: bearer == nil
        )

        // 3. Stream the speech for the shared ground-truth sentence via the real route.
        let expectedText = try loadExpectedText()
        let source = WorkerTTSChunkSource(client: client)
        let request = TTSStreamRequest(text: expectedText, voice: "alloy", speed: 1.0)

        var mp3 = Data()
        for try await chunk in await source.stream(request: request) {
            mp3.append(chunk.data)
        }
        #expect(mp3.count > 1000, "worker speech route returned too few bytes: \(mp3.count)")

        // 4. POST the MP3 to /api/audio/transcribe as JSON {audio: base64, mime_type}.
        //    TranscribeEndpoint is internal to RishiAPI, so issue a raw URLSession POST.
        var transcribeURL = baseURL
        transcribeURL.append(path: "/api/audio/transcribe")
        var post = URLRequest(url: transcribeURL)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { post.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        // The worker compares X-Dev-Bypass against DEV_BYPASS_SECRET via timingSafeEqual.
        post.setValue(devBypass ?? "1", forHTTPHeaderField: "X-Dev-Bypass")

        let payload: [String: String] = [
            "audio": mp3.base64EncodedString(),
            "mime_type": "audio/mpeg",
        ]
        post.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: post)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status == 200, "transcribe route returned HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")

        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)

        // 5. Fuzzy-assert the round-trip via TokenOverlap.
        let ratio = TokenOverlap.score(decoded.transcript, against: expectedText)
        #expect(ratio >= 0.6, "transcript drift too high: \(ratio) (got: \(decoded.transcript))")
    }
}
