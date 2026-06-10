import Testing
import Foundation
import SwiftUI
@testable import RishiSettings
import RishiCore

@MainActor
@Suite("Delete account flow + Account section")
struct DeleteAccountFlowTests {

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

    @Test("DeleteAccountFlow constructs in initial state")
    func deleteFlowInitial() {
        let view = DeleteAccountFlow(
            onDelete: {},
            onDeleted: {},
            onCancel: {}
        )
        _ = view.body
    }

    @Test("DeleteAccountFlow constructs with a throwing onDelete (error path)")
    func deleteFlowThrowsClosure() {
        struct Boom: Error {}
        let view = DeleteAccountFlow(
            onDelete: { throw Boom() },
            onDeleted: {},
            onCancel: {}
        )
        _ = view.body
    }
}
