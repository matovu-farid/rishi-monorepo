import Foundation
import Testing

@testable import rishi

@Suite("BackgroundSyncLifecycle Auto-Sync gate")
@MainActor
struct BackgroundSyncLifecycleGateTests {

    @Test("BGTask wave runs when Auto-Sync is ON")
    func bgTaskRunsWhenOn() {
        #expect(BackgroundSyncLifecycle.shouldRunBGTask(autoSync: true) == true)
    }

    @Test("BGTask wave skips when Auto-Sync is OFF")
    func bgTaskSkipsWhenOff() {
        #expect(
            BackgroundSyncLifecycle.shouldRunBGTask(autoSync: false) == false
        )
    }

    @Test("Silent-push wave runs when Auto-Sync is ON")
    func silentPushRunsWhenOn() {
        #expect(
            BackgroundSyncLifecycle.shouldRunSilentPush(autoSync: true) == true
        )
    }

    @Test("Silent-push wave skips when Auto-Sync is OFF")
    func silentPushSkipsWhenOff() {
        #expect(
            BackgroundSyncLifecycle.shouldRunSilentPush(autoSync: false)
                == false
        )
    }

    @Test("BGTask and silent-push gates agree for every flag value")
    func gatesAgree() {
        for flag in [true, false] {
            #expect(
                BackgroundSyncLifecycle.shouldRunBGTask(autoSync: flag)
                    == BackgroundSyncLifecycle.shouldRunSilentPush(
                        autoSync: flag
                    )
            )
        }
    }
    @Test("Foreground entry requests only authorized Auto Sync", arguments: ["authorized", "off", "denied", "signedOut"])
    func foregroundEntryHonorsAdmission(mode: String) async {
        let state = ForegroundState()
        if mode == "signedOut" { state.identity = nil }
        let lifecycle = BackgroundSyncLifecycle(foregroundIdentity: { state.identity }, resolveForegroundServices: { _ in
            state.resolutions += 1
            return .init(autoSync: mode != "off", isCurrentGraph: { true },
                hasConsent: { state.consentChecks += 1; return mode != "denied" },
                requestSync: { state.requests += 1 })
        })
        await lifecycle.foregroundDidActivate()
        #expect(state.requests == (mode == "authorized" ? 1 : 0))
        #expect(state.resolutions == (mode == "signedOut" ? 0 : 1))
        #expect(state.consentChecks == (mode == "signedOut" || mode == "off" ? 0 : 1))
    }

    @Test("Foreground entry rejects account or graph changed during an await", arguments: ["resolutionAccount", "resolutionGraph", "consentAccount", "consentGraph"])
    func foregroundEntryRechecksResolvedIdentity(mode: String) async {
        let state = ForegroundState()
        let gate = ForegroundGate()
        let lifecycle = BackgroundSyncLifecycle(foregroundIdentity: { state.identity }, resolveForegroundServices: { _ in
            if mode.hasPrefix("resolution") { await gate.suspend() }
            return .init(autoSync: true, isCurrentGraph: { state.graphCurrent },
                hasConsent: {
                    if mode.hasPrefix("consent") { await gate.suspend() }
                    return true
                }, requestSync: { state.requests += 1 })
        })
        let activation = Task { await lifecycle.foregroundDidActivate() }
        await gate.waitForEntry()
        if mode.hasSuffix("Account") { state.identity = LibraryAccountIdentity(userID: UUID(), generation: 2) }
        else { state.graphCurrent = false }
        await gate.release()
        await activation.value
        #expect(state.requests == 0)
    }

}


@MainActor
private final class ForegroundState {
    var identity: LibraryAccountIdentity? = LibraryAccountIdentity(userID: UUID(), generation: 1)
    var graphCurrent = true
    var resolutions = 0
    var consentChecks = 0
    var requests = 0
}

private actor ForegroundGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
