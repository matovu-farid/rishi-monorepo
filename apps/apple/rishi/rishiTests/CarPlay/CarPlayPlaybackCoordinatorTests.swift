import Foundation
import Testing
@testable import rishi

@MainActor
private final class FakeCarPlayPlaybackDriver: CarPlayPlaybackDriving {
    var activeBookID: BookID?
    var calls: [String] = []
    var startError: Error?
    var onStart: (() -> Void)?

    func start(bookID: BookID) async throws {
        calls.append("start")
        if let startError { throw startError }
        activeBookID = bookID
        onStart?()
    }

    func toggle() async { calls.append("toggle") }
    func pause() async { calls.append("pause") }
    func resume() async { calls.append("resume") }
    func next() async { calls.append("next") }
    func previous() async { calls.append("previous") }
    func stop() async { calls.append("stop"); activeBookID = nil }
    func releaseCarPlayHost() async { calls.append("release") }
}

@Suite("CarPlay playback coordinator")
@MainActor
struct CarPlayPlaybackCoordinatorTests {
    private let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let bookID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

    @Test("selecting a book starts the injected playback driver")
    func selectionStartsPlayback() async throws {
        let driver = FakeCarPlayPlaybackDriver()
        let coordinator = CarPlayPlaybackCoordinator(
            driver: driver,
            accountSnapshot: { CarPlayAccountSnapshot(userID: self.userID, generation: 1) },
            entitlementGate: { true }
        )

        let result = try await coordinator.select(bookID: bookID)

        #expect(result == .started)
        #expect(driver.activeBookID == bookID)
        #expect(driver.calls == ["start"])
    }

    @Test("selecting the active book toggles without starting a second session")
    func activeSelectionToggles() async throws {
        let driver = FakeCarPlayPlaybackDriver()
        driver.activeBookID = bookID
        let coordinator = CarPlayPlaybackCoordinator(
            driver: driver,
            accountSnapshot: { CarPlayAccountSnapshot(userID: self.userID, generation: 1) },
            entitlementGate: { true }
        )

        let result = try await coordinator.select(bookID: bookID)

        #expect(result == .toggled)
        #expect(driver.calls == ["toggle"])
    }

    @Test("entitlement failure never starts playback")
    func entitlementFailureDoesNotStart() async throws {
        let driver = FakeCarPlayPlaybackDriver()
        let coordinator = CarPlayPlaybackCoordinator(
            driver: driver,
            accountSnapshot: { CarPlayAccountSnapshot(userID: self.userID, generation: 1) },
            entitlementGate: { false }
        )

        let result = try await coordinator.select(bookID: bookID)

        #expect(result == .entitlementRequired)
        #expect(driver.calls.isEmpty)
    }

    @Test("account changes after start release the CarPlay host")
    func staleStartReleasesHost() async throws {
        let driver = FakeCarPlayPlaybackDriver()
        var snapshot: CarPlayAccountSnapshot? = CarPlayAccountSnapshot(
            userID: userID,
            generation: 1
        )
        driver.onStart = {
            snapshot = CarPlayAccountSnapshot(userID: UUID(), generation: 2)
        }
        let coordinator = CarPlayPlaybackCoordinator(
            driver: driver,
            accountSnapshot: { snapshot },
            entitlementGate: { true }
        )

        let result = try await coordinator.select(bookID: bookID)

        #expect(result == .staleAccount)
        #expect(driver.calls == ["start", "stop"])
    }

    @Test("CarPlay active-book state clears after a phone handoff")
    func activeBookRequiresCarPlayHostOwnership() {
        let carPlayHost = UUID()
        let phoneHost = UUID()
        let startedBook = bookID

        #expect(ReadAloudCarPlayDriver.activeBookID(
            ownerHost: carPlayHost,
            carPlayHost: carPlayHost,
            startedBookID: startedBook
        ) == startedBook)
        #expect(ReadAloudCarPlayDriver.activeBookID(
            ownerHost: phoneHost,
            carPlayHost: carPlayHost,
            startedBookID: startedBook
        ) == nil)
    }

    @Test("disconnect releases only the CarPlay host")
    func disconnectReleasesHost() async {
        let driver = FakeCarPlayPlaybackDriver()
        let coordinator = CarPlayPlaybackCoordinator(
            driver: driver,
            accountSnapshot: { CarPlayAccountSnapshot(userID: self.userID, generation: 1) },
            entitlementGate: { true }
        )

        await coordinator.disconnect()

        #expect(driver.calls == ["release"])
    }
}
