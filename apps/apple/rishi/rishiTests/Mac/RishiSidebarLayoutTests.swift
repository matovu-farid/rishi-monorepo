//
//  RishiSidebarLayoutTests.swift
//  rishiTests
//
//  Phase 12 Plan 12-02 — covers the layout-policy switch for `RishiSidebarLayout`.
//  Swift Testing only (no XCTest).
//
//  We do not snapshot SwiftUI here — those tests would need a host app and
//  a simulator. Instead we exercise:
//    - body builds without crash for both branches (smoke)
//    - the `prefersSidebar` policy returns the platform-correct default
//
//  On Mac Catalyst the policy is forced true; on plain iOS it follows the
//  `horizontalSizeClass`. SwiftUI's `@Environment` is not directly
//  injectable from outside a render pass, so the platform default branch
//  is the one we can assert here.
//

import Testing
import SwiftUI
@testable import rishi

@MainActor
@Suite("RishiSidebarLayout")
struct RishiSidebarLayoutTests {

    @Test("Body builds without crash (library selected)")
    func bodyBuildsLibrary() {
        let view = RishiSidebarLayout(
            selection: .constant(.library),
            library:    { Text("L") },
            chats:      { Text("C") },
            compactBody:{ Text("Tabs") }
        )
        _ = view.body
        #expect(Bool(true))
    }

    @Test("Body builds without crash (chats selected)")
    func bodyBuildsChats() {
        let view = RishiSidebarLayout(
            selection: .constant(.chats),
            library:    { Text("L") },
            chats:      { Text("C") },
            compactBody:{ Text("Tabs") }
        )
        _ = view.body
        #expect(Bool(true))
    }

    @Test("prefersSidebar policy matches platform default")
    func policyDefault() {
        let view = RishiSidebarLayout(
            selection: .constant(.library),
            library:    { Text("L") },
            chats:      { Text("C") },
            compactBody:{ Text("Tabs") }
        )
        // No horizontalSizeClass injected outside a render pass — the
        // environment default is `nil`, which the policy treats as
        // "not regular" → compact.
        //
        // On Mac Catalyst the #if branch wins and `prefersSidebar` is
        // unconditionally true; on iOS it is false until SwiftUI hands
        // us a real size class. This pins both shapes.
        #if targetEnvironment(macCatalyst)
        #expect(view.prefersSidebar == true)
        #else
        #expect(view.prefersSidebar == false)
        #endif
    }
}
