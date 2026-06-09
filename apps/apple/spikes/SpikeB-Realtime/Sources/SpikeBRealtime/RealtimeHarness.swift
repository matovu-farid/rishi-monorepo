// RealtimeHarness.swift
// Spike B — sustained voice session harness.
//
// What it validates:
//   1. Worker ephemeral-key flow: GET https://api.fidexa.org/api/realtime/client_secrets?language=en
//      with X-Dev-Bypass header (per reference_dev_bypass.md — the spike never
//      hand-rolls SIWA).
//   2. A 30-minute WebRTC voice session held against OpenAI Realtime using
//      m1guelpf/swift-realtime-openai, configured to match the electron
//      contract: voice=alloy, server VAD threshold 0.7, silence 700ms,
//      prefix padding 300ms (see INTEGRATIONS.md:44).
//   3. Recovery from a phone-call interruption (AVAudioSession route loss).
//   4. Tool-call serialization parity with electron's `buildRealtimeAgent.ts`
//      via the `endConversation` tool definition.
//
// Logging convention: every notable event prints with the `[SpikeB]` tag for
// log-grep verification.

import SwiftUI
import Foundation
import OSLog
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

import RealtimeAPI

// MARK: - Configuration

private enum SpikeBConfig {
    static let workerBaseURL = URL(string: "https://api.fidexa.org")!
    static let realtimeSecretsPath = "/api/realtime/client_secrets"
    static let language = "en"
    static let voice: Session.Voice = .alloy

    // Electron parity (INTEGRATIONS.md:44): server VAD threshold 0.7,
    // silence_duration_ms 700, prefix_padding_ms 300.
    static let vadThreshold: Double = 0.7
    static let silenceDurationMs: Int = 700
    static let prefixPaddingMs: Int = 300
}

private let signpostLog = OSLog(subsystem: "org.fidexa.spike-b", category: "realtime")

// MARK: - Worker ephemeral-key client

struct EphemeralKeyResponse: Decodable {
    let client_secret: ClientSecret
    struct ClientSecret: Decodable {
        let value: String
        let expires_at: Int?
    }
}

enum EphemeralKeyError: LocalizedError {
    case missingDevBypassSecret
    case http(status: Int, body: String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .missingDevBypassSecret:
            return "DEV_BYPASS_SECRET env var is not set. Set it before running the spike."
        case let .http(status, body):
            return "Worker returned HTTP \(status): \(body)"
        case let .decoding(err):
            return "Failed to decode ephemeral key response: \(err)"
        }
    }
}

actor EphemeralKeyClient {
    static let shared = EphemeralKeyClient()

    func fetchEphemeralKey() async throws -> String {
        guard let secret = ProcessInfo.processInfo.environment["DEV_BYPASS_SECRET"], !secret.isEmpty else {
            throw EphemeralKeyError.missingDevBypassSecret
        }

        var components = URLComponents(url: SpikeBConfig.workerBaseURL, resolvingAgainstBaseURL: false)!
        components.path = SpikeBConfig.realtimeSecretsPath
        components.queryItems = [URLQueryItem(name: "language", value: SpikeBConfig.language)]
        let url = components.url!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(secret, forHTTPHeaderField: "X-Dev-Bypass")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        print("[SpikeB] fetching ephemeral key from \(url)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EphemeralKeyError.http(status: -1, body: "no HTTPURLResponse")
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw EphemeralKeyError.http(status: http.statusCode, body: body)
        }
        do {
            let decoded = try JSONDecoder().decode(EphemeralKeyResponse.self, from: data)
            return decoded.client_secret.value
        } catch {
            throw EphemeralKeyError.decoding(error)
        }
    }
}

// MARK: - SwiftUI harness

@MainActor
@Observable
final class RealtimeHarnessModel {
    var sessionStartedAt: Date?
    var elapsedSeconds: Int = 0
    var connectionStatus: String = "idle"
    var lastEvent: String = "(none)"
    var audioFramesSent: Int = 0
    var audioFramesReceived: Int = 0
    var disconnectCount: Int = 0
    var lastError: String?

    private(set) var conversation: Conversation?
    private var statusObservationTask: Task<Void, Never>?
    private var errorObservationTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    func start() async {
        guard conversation == nil else {
            print("[SpikeB] start: session already running")
            return
        }
        do {
            sessionStartedAt = Date()
            elapsedSeconds = 0
            audioFramesSent = 0
            audioFramesReceived = 0
            lastError = nil
            connectionStatus = "fetching ephemeral key"
            lastEvent = "start requested"

            configureAudioSession()
            installAudioSessionObservers()

            let ephemeralKey = try await EphemeralKeyClient.shared.fetchEphemeralKey()

            // os_signpost lets Instruments surface this as a known interval.
            os_signpost(.begin, log: signpostLog, name: "voice-session")

            connectionStatus = "constructing conversation"
            let convo = Conversation(debug: true) { session in
                // Voice + VAD parity with electron client.
                // Session.AudioFormat exposes only a synthesized memberwise
                // init at internal access. Round-trip through JSON to construct
                // it from outside the module.
                let pcm24k: Session.AudioFormat = {
                    let data = try! JSONSerialization.data(withJSONObject: [
                        "rate": 24000,
                        "type": "pcm",
                    ])
                    return try! JSONDecoder().decode(Session.AudioFormat.self, from: data)
                }()
                let input = Session.Audio.Input(
                    format: pcm24k,
                    noiseReduction: nil,
                    transcription: nil,
                    turnDetection: .serverVad(
                        prefixPaddingMs: SpikeBConfig.prefixPaddingMs,
                        silenceDurationMs: SpikeBConfig.silenceDurationMs,
                        threshold: SpikeBConfig.vadThreshold
                    )
                )
                let output = Session.Audio.Output(
                    voice: SpikeBConfig.voice,
                    speed: 1.0,
                    format: pcm24k
                )
                session.audio = Session.Audio(input: input, output: output)

                // Tool-call parity: declare an `endConversation` tool, mirroring
                // electron's buildRealtimeAgent.ts. The harness does not handle
                // the call — we just confirm the SDK transmits the definition.
                let endConversation: Tool = .function(.init(
                    name: "endConversation",
                    description: "Politely end the conversation. The host UI will tear down the call.",
                    parameters: .object(properties: [:])
                ))
                if session.tools == nil {
                    session.tools = []
                }
                session.tools?.append(endConversation)
            }
            self.conversation = convo

            observeConnectionStatus(convo)
            observeErrors(convo)
            startTicker()

            connectionStatus = "connecting"
            try await convo.connect(ephemeralKey: ephemeralKey)
            connectionStatus = "connected"
            lastEvent = "connected at \(formattedNow())"
            print("[SpikeB] event=connected at \(Date())")
            os_signpost(.event, log: signpostLog, name: "connected")
        } catch {
            connectionStatus = "failed"
            lastError = error.localizedDescription
            print("[SpikeB] event=connect_failed error=\(error)")
            os_signpost(.end, log: signpostLog, name: "voice-session", "failed")
            await stop()
        }
    }

    func stop() async {
        statusObservationTask?.cancel()
        statusObservationTask = nil
        errorObservationTask?.cancel()
        errorObservationTask = nil
        tickerTask?.cancel()
        tickerTask = nil

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }

        conversation = nil
        connectionStatus = "disconnected"
        lastEvent = "disconnected at \(formattedNow())"
        os_signpost(.end, log: signpostLog, name: "voice-session", "stopped")
        print("[SpikeB] event=disconnected at \(Date())")
    }

    private func observeConnectionStatus(_ convo: Conversation) {
        statusObservationTask?.cancel()
        statusObservationTask = Task { @MainActor [weak self] in
            // We poll the @Observable `status` property at 1Hz — the library
            // exposes status as a property, not a stream.
            var previous: RealtimeAPI.Status = .disconnected
            while !Task.isCancelled {
                let status = convo.status
                if status != previous {
                    self?.connectionStatus = String(describing: status)
                    self?.lastEvent = "status=\(status) at \(self?.formattedNow() ?? "")"
                    print("[SpikeB] event=status_change to=\(status) at \(Date())")
                    if previous == .connected, status == .disconnected {
                        self?.disconnectCount += 1
                    }
                    previous = status
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func observeErrors(_ convo: Conversation) {
        errorObservationTask?.cancel()
        errorObservationTask = Task { @MainActor [weak self] in
            for await error in convo.errors {
                guard let self else { return }
                self.lastError = "\(error)"
                self.lastEvent = "error: \(error)"
                print("[SpikeB] event=server_error \(error) at \(Date())")
            }
        }
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let start = self?.sessionStartedAt {
                    self?.elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func configureAudioSession() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            print("[SpikeB] audio session configured (playAndRecord/voiceChat)")
        } catch {
            print("[SpikeB] event=audio_session_failed error=\(error)")
        }
        #endif
    }

    private func installAudioSessionObservers() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        let center = NotificationCenter.default
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reasonValue = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) ?? .unknown
            print("[SpikeB] event=route_change reason=\(reason)")
            Task { @MainActor in self?.lastEvent = "route_change \(reason)" }
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let typeValue = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) ?? .began
            print("[SpikeB] event=interruption type=\(type)")
            Task { @MainActor in self?.lastEvent = "interruption \(type)" }
        }
        #endif
    }

    private func formattedNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

struct RealtimeHarness: View {
    @State private var model = RealtimeHarnessModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spike B — swift-realtime-openai")
                .font(.title2.bold())

            Text("Worker: https://api.fidexa.org/api/realtime/client_secrets?language=en")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Divider()

            metricsView

            Divider()

            HStack(spacing: 12) {
                Button {
                    Task { await model.start() }
                } label: {
                    Label("Start session", systemImage: "phone.connection.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.conversation != nil)

                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("Disconnect", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.conversation == nil)
            }

            if let err = model.lastError {
                Text("Last error: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var metricsView: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Status:").bold()
                Text(model.connectionStatus)
                    .foregroundStyle(model.connectionStatus == "connected" ? .green : .primary)
            }
            GridRow {
                Text("Elapsed:").bold()
                Text(formatElapsed(model.elapsedSeconds))
                    .font(.body.monospacedDigit())
            }
            GridRow {
                Text("Disconnects:").bold()
                Text("\(model.disconnectCount)")
            }
            GridRow {
                Text("Frames sent:").bold()
                Text("\(model.audioFramesSent)")
            }
            GridRow {
                Text("Frames received:").bold()
                Text("\(model.audioFramesReceived)")
            }
            GridRow {
                Text("Last event:").bold()
                Text(model.lastEvent).font(.caption.monospaced())
            }
        }
    }

    private func formatElapsed(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
