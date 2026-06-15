//
//  LibraryNavigationUITests.swift
//  rishiUITests
//
//  Regression guard for the tab-bar removal: on iPhone (compact) the bottom
//  tab bar is gone, Library is the single home, and a "Chats" toolbar button
//  pushes the conversations list onto Library's NavigationStack.
//

import XCTest

final class LibraryNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNoTabBarAndChatsButtonPushesConversations() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launch()

        // Library appears.
        let bookCell = app.descendants(matching: .any)
            .matching(identifier: "library-book-cell")
            .firstMatch
        XCTAssertTrue(
            bookCell.waitForExistence(timeout: 30),
            "Library never showed a book cell — auth bypass or sample-book seed failed."
        )

        // No bottom tab bar: the old Library tab (identifier "books.vertical")
        // must be gone. (The Chats toolbar button uses a different identifier.)
        let oldLibraryTab = app.descendants(matching: .any)
            .matching(identifier: "books.vertical")
            .firstMatch
        XCTAssertFalse(
            oldLibraryTab.exists,
            "Bottom tab bar still present — the iPhone TabView was not removed."
        )

        // The Chats toolbar button is present (compact-only entry point).
        let chats = app.descendants(matching: .any)
            .matching(identifier: "library.toolbar.chats")
            .firstMatch
        XCTAssertTrue(
            chats.waitForExistence(timeout: 10),
            "Library toolbar Chats button missing — compact Chats entry point not wired."
        )
        robustTap(chats)

        // Tapping it pushes the Conversations list onto the Library stack.
        XCTAssertTrue(
            app.navigationBars["Conversations"].waitForExistence(timeout: 10),
            "Conversations list did not push onto the Library NavigationStack."
        )
    }

    /// Coordinate tap — SwiftUI toolbar buttons can report isHittable=false in a
    /// scroll/overlay context; a coordinate tap does no hittability check.
    @MainActor
    private func robustTap(_ element: XCUIElement) {
        usleep(300_000)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
