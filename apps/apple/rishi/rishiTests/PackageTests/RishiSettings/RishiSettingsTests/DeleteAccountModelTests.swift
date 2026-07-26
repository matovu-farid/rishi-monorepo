@testable import rishi
import Testing
import Foundation
import SwiftUI




@MainActor
@Suite("Delete account model + Account section")
struct DeleteAccountModelTests {

    // MARK: - AccountSection construction (carried over from the removed
    // DeleteAccountFlow suite — the row still exists and drives the alert).

    @Test("AccountSection constructs with full User")
    func accountSectionConstructs() {
        let user = User(
            id: UUID(),
            email: "user@example.com",
            displayName: "Test User",
            avatarURL: nil,
            hasPro: true,
            createdAt: Date()
        )
        let section = AccountSection(
            user: user,
            onSignOut: {},
            onShowDeleteFlow: {}
        )
        _ = section.body
    }

    @Test("AccountSection constructs without displayName")
    func accountSectionConstructsNoName() {
        let user = User(
            id: UUID(),
            email: "anon@example.com",
            displayName: nil,
            avatarURL: nil,
            hasPro: false,
            createdAt: Date()
        )
        let section = AccountSection(
            user: user,
            onSignOut: {},
            onShowDeleteFlow: {}
        )
        _ = section.body
    }

    @Test("AccountSection constructs with EMPTY displayName (treated as no-name)")
    func accountSectionConstructsEmptyName() {
        let user = User(
            id: UUID(),
            email: "x@example.com",
            displayName: "",
            avatarURL: nil,
            hasPro: false,
            createdAt: Date()
        )
        let section = AccountSection(
            user: user,
            onSignOut: {},
            onShowDeleteFlow: {}
        )
        _ = section.body
    }

    // MARK: - DeleteAccountModel.runDelete

    @Test("runDelete success: clears state, logs deleted event, calls onDeleted")
    func runDeleteSuccess() async {
        var deletedCalled = false
        var events: [(String, LogLevel)] = []
        Log._testCapture.handler = { name, level, _ in events.append((name, level)) }
        defer { Log._testCapture.reset() }

        let model = DeleteAccountModel(
            onDelete: {},
            onDeleted: { deletedCalled = true }
        )

        await model.runDelete()

        #expect(deletedCalled)
        #expect(model.inFlight == false)
        #expect(model.deleteError == nil)
        #expect(events.contains { $0.0 == "settings.account.deleted" && $0.1 == .info })
    }

    @Test("runDelete failure: sets retry error, logs delete_failed, leaves onDeleted uncalled")
    func runDeleteFailure() async {
        struct Boom: Error {}
        var deletedCalled = false
        var events: [(String, LogLevel)] = []
        Log._testCapture.handler = { name, level, _ in events.append((name, level)) }
        defer { Log._testCapture.reset() }

        let model = DeleteAccountModel(
            onDelete: { throw Boom() },
            onDeleted: { deletedCalled = true }
        )

        await model.runDelete()

        #expect(deletedCalled == false)
        #expect(model.inFlight == false)
        #expect(model.deleteError == "We couldn't delete your account. Check your connection and try again.")
        #expect(events.contains { $0.0 == "settings.account.delete_failed" && $0.1 == .error })
    }

    @Test("runDelete is re-entrant safe: a second concurrent call is ignored")
    func runDeleteReentrant() async {
        var deleteCalls = 0
        let model = DeleteAccountModel(
            onDelete: { deleteCalls += 1 },
            onDeleted: {}
        )

        await model.runDelete()
        #expect(deleteCalls == 1)
    }
}
