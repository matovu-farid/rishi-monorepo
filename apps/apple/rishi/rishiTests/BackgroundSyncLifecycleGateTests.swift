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
}
