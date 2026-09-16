import Foundation
import os

/// DEBUG-simulator-only `LogSink` that mirrors every structured log event into
/// reset-on-launch dump files inside the simulator's app sandbox.
///
/// ## Why
/// When the user runs the app in the iOS Simulator and reports a bug, the
/// host (Claude Code / orchestrator) can read the dump from the Mac via
/// `xcrun simctl get_app_container booted org.fidexa.rishi data`
/// and see exactly what happened. Patterned after the Tauri/Electron
/// `apps/main/error-dump.json` equivalent.
///
/// ## Streams
/// On init the entire dump directory is wiped and recreated. Then five files
/// are opened for append:
///
/// - `all.log` — every event (NDJSON, one JSON object per line)
/// - `errors.log` — events at level `.error` or `.fatal`
/// - `warnings.log` — events at level `.warning`
/// - `events.log` — every event (alias of `all.log` for symmetry with
///   `apps/main`'s legacy split; useful when filtering errors out of the
///   common event stream during triage)
/// - `network.log` — events whose name starts with `api.`, `worker.`, or
///   `sync.` (the worker-client traffic surface)
///
/// A sixth file `path.txt` is written once with the absolute resolved path of
/// the dump directory, so the host script can echo it back when the simulator
/// container path is unknown.
///
/// ## Concurrency
/// `record(name:level:data:)` is `nonisolated` and **non-blocking**: it
/// serializes the encoded line into a private serial `DispatchQueue` and
/// returns immediately. The queue owns the open `FileHandle`s so a single
/// write per stream per event happens off the calling thread/actor.
///
/// ## Gate
/// `SimulatorDumpSink.make()` returns `nil` outside of
/// `DEBUG && targetEnvironment(simulator)`. The test-only factory
/// `makeForTesting(at:)` bypasses the gate so unit tests can exercise the
/// sink on the macOS test host.
public final class SimulatorDumpSink: LogSink, @unchecked Sendable {

    // MARK: - Public factories

    /// Production factory. Returns `nil` outside `DEBUG && simulator`. On a
    /// real device or in Release the dump sink is a no-op (a nil return means
    /// `AppDependencies` simply skips `Log.installSink(...)`).
    ///
    /// On a successful init in the simulator the dump directory is
    /// `<NSTemporaryDirectory>/rishi-dump/`, which resolves on the host to
    /// `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Data/Application/<APPID>/tmp/rishi-dump/`.
    public static func make() -> SimulatorDumpSink? {
        #if DEBUG && targetEnvironment(simulator)
        let url = NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: url).appendingPathComponent("rishi-dump", isDirectory: true)
        return try? SimulatorDumpSink(directory: dir)
        #else
        return nil
        #endif
    }

    /// Test-only factory: bypasses the DEBUG-simulator gate and roots the sink
    /// at a caller-supplied directory. The directory is wiped + recreated on
    /// init exactly like the production factory.
    public static func makeForTesting(at directory: URL) throws -> SimulatorDumpSink {
        try SimulatorDumpSink(directory: directory)
    }

    // MARK: - Private state

    /// Resolved on-disk root of the dump directory.
    public let directory: URL

    private let queue = DispatchQueue(label: "org.fidexa.rishi.dump.sink", qos: .utility)
    private let encoder: JSONEncoder

    // Open file handles (one per stream). Owned by the queue; mutated only on
    // the queue. The class is `@unchecked Sendable` because every observable
    // mutation happens behind the serial queue.
    private var allHandle: FileHandle?
    private var errorsHandle: FileHandle?
    private var warningsHandle: FileHandle?
    private var eventsHandle: FileHandle?
    private var networkHandle: FileHandle?

    private let oslog = Logger(subsystem: "org.fidexa.rishi.dump", category: "sink")

    // MARK: - Init

    private init(directory: URL) throws {
        self.directory = directory

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let fm = FileManager.default

        // Reset on launch: blow away the directory and recreate it.
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Touch each stream and open a writable handle in append mode.
        self.allHandle      = try Self.openStream(directory.appendingPathComponent("all.log"))
        self.errorsHandle   = try Self.openStream(directory.appendingPathComponent("errors.log"))
        self.warningsHandle = try Self.openStream(directory.appendingPathComponent("warnings.log"))
        self.eventsHandle   = try Self.openStream(directory.appendingPathComponent("events.log"))
        self.networkHandle  = try Self.openStream(directory.appendingPathComponent("network.log"))

        // Write the resolved path so the host script can `cat path.txt`.
        let pathFile = directory.appendingPathComponent("path.txt")
        try directory.path.write(to: pathFile, atomically: true, encoding: .utf8)

        // Make the path discoverable via `xcrun simctl spawn booted log show
        // --predicate 'subsystem == "org.fidexa.rishi.dump"' --last 30s`.
        oslog.info("rishi dump sink active at \(directory.path, privacy: .public)")
    }

    deinit {
        // Close handles synchronously — deinit runs on the last releaser's
        // thread and the queue might be empty already.
        try? allHandle?.close()
        try? errorsHandle?.close()
        try? warningsHandle?.close()
        try? eventsHandle?.close()
        try? networkHandle?.close()
    }

    /// Explicitly close the sink. Idempotent. Used by tests so the directory
    /// can be removed without dangling file handles.
    public func close() {
        queue.sync {
            try? self.allHandle?.close()
            try? self.errorsHandle?.close()
            try? self.warningsHandle?.close()
            try? self.eventsHandle?.close()
            try? self.networkHandle?.close()
            self.allHandle = nil
            self.errorsHandle = nil
            self.warningsHandle = nil
            self.eventsHandle = nil
            self.networkHandle = nil
        }
    }

    // MARK: - LogSink

    public func record(name: String, level: LogLevel, data: [String: String]?) {
        let payload = WirePayload(
            ts: Date(),
            level: level.rawValue,
            message: name,
            fields: data
        )
        let line: Data
        do {
            var encoded = try encoder.encode(payload)
            encoded.append(0x0A) // newline — NDJSON
            line = encoded
        } catch {
            return
        }

        let isNetwork = Self.isNetworkEvent(name)

        queue.async { [weak self] in
            guard let self else { return }
            self.write(line, to: self.allHandle)
            switch level {
            case .error, .fatal:
                self.write(line, to: self.errorsHandle)
            case .warning:
                self.write(line, to: self.warningsHandle)
            case .debug, .info:
                break
            }
            self.write(line, to: self.eventsHandle)
            if isNetwork {
                self.write(line, to: self.networkHandle)
            }
        }
    }

    /// Block until the serial queue has drained. **Test-only** — production
    /// callers fire-and-forget through `record(...)`.
    public func flushForTesting() {
        queue.sync {}
    }

    // MARK: - Internals

    private func write(_ data: Data, to handle: FileHandle?) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Swallow — dump sink must never crash the app.
        }
    }

    private static func openStream(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// Prefixes whose events count as "network traffic" for `network.log`.
    /// Matches the worker-client + sync engine + auth-network surfaces.
    private static let networkPrefixes: [String] = [
        "api.",
        "worker.",
        "sync.",
        "auth.siwa.",
        "billing.entitlement.",
    ]

    private static func isNetworkEvent(_ name: String) -> Bool {
        for prefix in networkPrefixes where name.hasPrefix(prefix) {
            return true
        }
        return false
    }
}

// MARK: - Wire payload

/// One NDJSON line. Fields ordered intentionally so the most useful columns
/// (`ts`, `level`, `message`) appear first when the file is read top-to-bottom
/// during triage.
private struct WirePayload: Encodable {
    let ts: Date
    let level: String
    let message: String
    let fields: [String: String]?
}
