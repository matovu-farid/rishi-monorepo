//
//  BackgroundSyncLifecycleGateTests.swift
//  rishiTests
//
//  Plan 34-14 SRP split — pins the Auto-Sync gate decision now centralised in
//  `BackgroundSyncLifecycle`. The BGTask gate (previously inline in
//  `AppDependencies.driveBGTask`) and the silent-push gate (previously
//  duplicated in `rishiApp`'s AppDelegate) both read the SAME gate condition;
//  these tests prove the two pure seams agree on on -> run / off -> skip so a
//  future drift between the two copies can't reappear silently.
//
//  Swift Testing only. The decision functions are pure + `#if`-free so they
//  run on every target without bootstrapping the heavy service graph.
//

import Testing
@testable import rishi

@Suite("BackgroundSyncLifecycle Auto-Sync gate")
struct BackgroundSyncLifecycleGateTests {

    @Test("BGTask wave runs when Auto-Sync is ON")
    func bgTaskRunsWhenOn() {
        #expect(BackgroundSyncLifecycle.shouldRunBGTask(autoSync: true) == true)
    }

    @Test("BGTask wave skips when Auto-Sync is OFF")
    func bgTaskSkipsWhenOff() {
        #expect(BackgroundSyncLifecycle.shouldRunBGTask(autoSync: false) == false)
    }

    @Test("Silent-push wave runs when Auto-Sync is ON")
    func silentPushRunsWhenOn() {
        #expect(BackgroundSyncLifecycle.shouldRunSilentPush(autoSync: true) == true)
    }

    @Test("Silent-push wave skips when Auto-Sync is OFF")
    func silentPushSkipsWhenOff() {
        #expect(BackgroundSyncLifecycle.shouldRunSilentPush(autoSync: false) == false)
    }

    /// Regression guard against the two prior copies drifting apart again:
    /// the BGTask and silent-push gates MUST make the same decision for any
    /// flag value (they share the `shouldRunAutoSync` condition; only the
    /// skip *action* differs).
    @Test("BGTask and silent-push gates agree for every flag value")
    func gatesAgree() {
        for flag in [true, false] {
            #expect(
                BackgroundSyncLifecycle.shouldRunBGTask(autoSync: flag)
                    == BackgroundSyncLifecycle.shouldRunSilentPush(autoSync: flag)
            )
        }
    }
}
