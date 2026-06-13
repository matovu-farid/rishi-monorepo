import Foundation
import Testing
@testable import RishiLogging

/// Tests for `SimulatorDumpSink`.
///
/// The production factory `SimulatorDumpSink.make()` returns nil outside of
/// `DEBUG && targetEnvironment(simulator)` so test-runner hosts (macOS,
/// non-simulator) cannot exercise it. To still cover the behavior we use
/// the bypass factory `SimulatorDumpSink.makeForTesting(at:)` which builds
/// a sink rooted at a caller-supplied URL.
@Suite("SimulatorDumpSink")
struct SimulatorDumpSinkTests {

    /// Build a brand-new tmp dir for one test. Caller is responsible for
    /// constructing the sink against it and tearing it down at the end.
    private func makeTmpDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-dump-tests-\(label)-\(UUID().uuidString)")
        return url
    }

    @Test func initResetsDirectory() throws {
        let dir = makeTmpDir("reset")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-populate the directory with a junk file the sink must wipe.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent("stale.log")
        try "stale data".write(to: stale, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: stale.path))

        // Constructing the sink must wipe the entire directory and recreate it.
        let sink = try SimulatorDumpSink.makeForTesting(at: dir)
        defer { sink.close() }

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // path.txt is written on init.
        let pathFile = dir.appendingPathComponent("path.txt")
        #expect(FileManager.default.fileExists(atPath: pathFile.path))
    }

    @Test func errorWritesToErrorsLogAndAllLog() throws {
        let dir = makeTmpDir("errors")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = try SimulatorDumpSink.makeForTesting(at: dir)
        defer { sink.close() }

        sink.record(name: "boom", level: .error, data: ["k": "v"])
        sink.flushForTesting()

        let errors = try String(contentsOf: dir.appendingPathComponent("errors.log"), encoding: .utf8)
        let all = try String(contentsOf: dir.appendingPathComponent("all.log"), encoding: .utf8)
        #expect(errors.contains("boom"))
        #expect(all.contains("boom"))

        // Warnings + events files do NOT contain an error-level event.
        let warnings = try String(contentsOf: dir.appendingPathComponent("warnings.log"), encoding: .utf8)
        #expect(!warnings.contains("boom"))
    }

    @Test func warningWritesToWarningsLogOnly() throws {
        let dir = makeTmpDir("warnings")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = try SimulatorDumpSink.makeForTesting(at: dir)
        defer { sink.close() }

        sink.record(name: "soft.fail", level: .warning, data: nil)
        sink.flushForTesting()

        let warnings = try String(contentsOf: dir.appendingPathComponent("warnings.log"), encoding: .utf8)
        let errors = try String(contentsOf: dir.appendingPathComponent("errors.log"), encoding: .utf8)
        let all = try String(contentsOf: dir.appendingPathComponent("all.log"), encoding: .utf8)
        #expect(warnings.contains("soft.fail"))
        #expect(all.contains("soft.fail"))
        #expect(!errors.contains("soft.fail"))
    }

    @Test func eventWritesToEventsLogAndAllLog() throws {
        let dir = makeTmpDir("events")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = try SimulatorDumpSink.makeForTesting(at: dir)
        defer { sink.close() }

        sink.record(name: "auth.signed_in", level: .info, data: ["user": "u1"])
        sink.flushForTesting()

        let events = try String(contentsOf: dir.appendingPathComponent("events.log"), encoding: .utf8)
        let all = try String(contentsOf: dir.appendingPathComponent("all.log"), encoding: .utf8)
        #expect(events.contains("auth.signed_in"))
        #expect(all.contains("auth.signed_in"))
    }

    @Test func networkEventsLandInNetworkLog() throws {
        let dir = makeTmpDir("network")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = try SimulatorDumpSink.makeForTesting(at: dir)
        defer { sink.close() }

        sink.record(name: "api.request.completed", level: .info, data: nil)
        sink.record(name: "worker.error", level: .error, data: nil)
        sink.record(name: "sync.fetch.started", level: .info, data: nil)
        sink.record(name: "iap.purchase.granted", level: .info, data: nil)
        sink.flushForTesting()

        let network = try String(contentsOf: dir.appendingPathComponent("network.log"), encoding: .utf8)
        #expect(network.contains("api.request.completed"))
        #expect(network.contains("worker.error"))
        #expect(network.contains("sync.fetch.started"))
        // Non-network events do not land in network.log.
        #expect(!network.contains("iap.purchase.granted"))
    }

    @Test func ndjsonFormatIsParseable() throws {
        let dir = makeTmpDir("ndjson")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = try SimulatorDumpSink.makeForTesting(at: dir)
        defer { sink.close() }

        sink.record(name: "demo.event", level: .info, data: ["a": "1", "b": "two"])
        sink.flushForTesting()

        let raw = try String(contentsOf: dir.appendingPathComponent("all.log"), encoding: .utf8)
        let line = raw.split(separator: "\n").first.map(String.init) ?? ""
        let data = Data(line.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["message"] as? String == "demo.event")
        #expect(obj?["level"] as? String == "info")
        let fields = obj?["fields"] as? [String: String]
        #expect(fields?["a"] == "1")
        #expect(fields?["b"] == "two")
    }

    @Test func sinkReceivesLogEventCallsViaRegistration() throws {
        let dir = makeTmpDir("register")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = try SimulatorDumpSink.makeForTesting(at: dir)
        Log.installSink(sink)
        defer {
            Log.removeSink(sink)
            sink.close()
        }

        Log.event("integration.fire", level: .warning, data: ["hi": "there"])
        Log.error("integration.error")

        sink.flushForTesting()

        let all = try String(contentsOf: dir.appendingPathComponent("all.log"), encoding: .utf8)
        #expect(all.contains("integration.fire"))
        // Log.error also notifies sinks at error level.
        #expect(all.contains("integration.error"))

        let errors = try String(contentsOf: dir.appendingPathComponent("errors.log"), encoding: .utf8)
        #expect(errors.contains("integration.error"))
    }

    @Test func productionMakeReturnsNilOutsideSimulator() {
        // On the macOS Swift test host, the production factory returns nil
        // because the simulator/DEBUG gate is not satisfied. The bypass
        // factory `makeForTesting` continues to work.
        #if !targetEnvironment(simulator) || !DEBUG
        let sink = SimulatorDumpSink.make()
        #expect(sink == nil)
        #endif
    }
}
