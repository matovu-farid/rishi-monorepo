@testable import rishi
import Foundation
import Testing


@Suite("RishiLogging smoke")
struct LogSmokeTests {

    @Test func startWithNilDsnDoesNotCrash() {
        RishiLogging.start(dsn: nil, environment: "test", release: "0.0.0")
        Log.event("smoke.event", level: .info, data: ["k": "v"])
        Log.error("smoke.error", error: nil)
    }

    @Test func startWithEmptyDsnIsNoOp() {
        RishiLogging.start(dsn: "", environment: "test", release: "0.0.0")
        Log.event("smoke.event.empty", level: .debug, data: nil)
    }

    @Test func sixSubsystemsExist() {
        // All six Logger instances are reachable; static lookups must compile + run.
        _ = Log.app
        _ = Log.api
        _ = Log.reader
        _ = Log.audio
        _ = Log.sync
        _ = Log.auth
        #expect(Log.subsystem == "org.fidexa.rishi")
    }

    @Test func logLevelsMapToOSLogTypes() {
        // Pure mapping check — no logging side effects under test.
        #expect(LogLevel.debug.osLogType == .debug)
        #expect(LogLevel.info.osLogType == .info)
        #expect(LogLevel.error.osLogType == .error)
        #expect(LogLevel.fatal.osLogType == .fault)
    }
}
