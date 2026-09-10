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

        let bookCell = app.descendants(matching: .any)
            .matching(identifier: "library-book-cell")
            .firstMatch
        XCTAssertTrue(
            bookCell.waitForExistence(timeout: 30),
            "Library never showed a book cell — auth bypass or sample-book seed failed."
        )

        let oldLibraryTab = app.descendants(matching: .any)
            .matching(identifier: "books.vertical")
            .firstMatch
        XCTAssertFalse(
            oldLibraryTab.exists,
            "Bottom tab bar still present — the iPhone TabView was not removed."
        )

        let chats = app.descendants(matching: .any)
            .matching(identifier: "library.toolbar.chats")
            .firstMatch
        XCTAssertTrue(
            chats.waitForExistence(timeout: 10),
            "Library toolbar Chats button missing — compact Chats entry point not wired."
        )
        robustTap(chats)

        XCTAssertTrue(
            app.navigationBars["Conversations"].waitForExistence(timeout: 10),
            "Conversations list did not push onto the Library NavigationStack."
        )
    }

    @MainActor
    private func robustTap(_ element: XCUIElement) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 5),
            "Expected the Chats control to remain available before tapping."
        )
        XCTAssertTrue(element.isHittable, "Expected the Chats control to be hittable.")
        element.tap()
    }
}
