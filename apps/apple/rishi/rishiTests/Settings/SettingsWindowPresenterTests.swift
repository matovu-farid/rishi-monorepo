//
//  SettingsWindowPresenterTests.swift
//  rishiTests
//
//  Phase 32 Plan 32-01 — pins the single-instance open-flag behavior of the
//  dedicated Mac Settings window backstop. Swift Testing only (no XCTest).
//

import Testing
import SwiftUI
@testable import rishi

@MainActor
@Suite("SettingsWindowPresenter")
struct SettingsWindowPresenterTests {

    @Test("Starts closed; shouldOpen is true")
    func startsClosed() {
        let p = SettingsWindowPresenter()
        #expect(p.isOpen == false)
        #expect(p.shouldOpen == true)
    }

    @Test("markOpened sets isOpen true; shouldOpen becomes false")
    func markOpened() {
        let p = SettingsWindowPresenter()
        p.markOpened()
        #expect(p.isOpen == true)
        #expect(p.shouldOpen == false)
    }

    @Test("markClosed resets isOpen false; shouldOpen true again")
    func markClosed() {
        let p = SettingsWindowPresenter()
        p.markOpened()
        p.markClosed()
        #expect(p.isOpen == false)
        #expect(p.shouldOpen == true)
    }
}
