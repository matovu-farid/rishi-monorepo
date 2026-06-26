










import Testing
@testable import rishi

@Suite("shouldRunAutoSync gate")
struct AutoSyncGateTests {

    @Test("auto sync runs when the flag is ON")
    func runsWhenOn() {
        #expect(shouldRunAutoSync(true) == true)
    }

    @Test("auto sync short-circuits when the flag is OFF")
    func skipsWhenOff() {
        #expect(shouldRunAutoSync(false) == false)
    }
}
