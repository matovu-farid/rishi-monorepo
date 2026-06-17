//
//  AutoSyncGateTests.swift
//  rishiTests
//
//  Phase 33 Plan 33-01 — pins the pure auto-sync gate decision the three
//  automatic-sync entry points read in Wave 2. `shouldRunAutoSync(_:)` is a
//  #if-free free function (lives OUTSIDE the macCatalyst gate in
//  ReaderPrefsMenuModel.swift) so it is testable on every target. Manual
//  "Sync Now" never consults this gate. Swift Testing only.
//

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
