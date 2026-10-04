import Foundation
import Testing
@testable import rishi

@MainActor
private final class FakeCarPlayPlaybackDriver: CarPlayPlaybackDriving {
    var activeBookID: BookID?
    var onSourceUnavailable: (@MainActor (BookID, CarPlayAccountSnapshot) -> Void)?
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
    func accountDidChange() async { calls.append("accountChange") }
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

    @Test("source invalidation is surfaced only for the active captured account")
    func sourceUnavailablePublicationIsAccountScoped() {
        let account = CarPlayAccountSnapshot(userID: userID, generation: 3)

        #expect(CarPlaySessionCoordinator.shouldPublishSourceUnavailable(
            isActive: true,
            capturedAccount: account,
            currentAccount: account
        ))
        #expect(!CarPlaySessionCoordinator.shouldPublishSourceUnavailable(
            isActive: false,
            capturedAccount: account,
            currentAccount: account
        ))
        #expect(!CarPlaySessionCoordinator.shouldPublishSourceUnavailable(
            isActive: true,
            capturedAccount: account,
            currentAccount: CarPlayAccountSnapshot(userID: userID, generation: 4)
        ))
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

    @Test("CarPlay accepts a source lease only for its captured account and book")
    func sourceLeaseMustMatchCapturedAccount() {
        let account = CarPlayAccountSnapshot(userID: userID, generation: 7)
        let permit = BookReadingPermit(
            ownerID: userID,
            accountGeneration: account.generation,
            bookID: bookID,
            contentRevision: UUID()
        )

        #expect(ReadAloudCarPlayDriver.readingPermit(
            from: .account(permit),
            bookID: bookID,
            account: account
        ) == permit)
        #expect(ReadAloudCarPlayDriver.readingPermit(
            from: .account(permit),
            bookID: bookID,
            account: CarPlayAccountSnapshot(userID: userID, generation: 8)
        ) == nil)
        #expect(ReadAloudCarPlayDriver.readingPermit(
            from: .account(permit),
            bookID: UUID(),
            account: account
        ) == nil)
        #expect(ReadAloudCarPlayDriver.readingPermit(
            from: .localPreview,
            bookID: bookID,
            account: account
        ) == nil)
    }

    @Test("invalidation during load rejects only the pending reader and active invalidation stops it")
    func sourceInvalidationDispositionTracksPlaybackOwnership() {
        let pendingObservation = UUID()
        let activeObservation = UUID()

        #expect(ReadAloudCarPlayDriver.invalidationDisposition(
            invalidatedObservationID: pendingObservation,
            activeObservationID: activeObservation,
            accountIsCurrent: true
        ) == .rejectPendingStart)
        #expect(ReadAloudCarPlayDriver.invalidationDisposition(
            invalidatedObservationID: activeObservation,
            activeObservationID: activeObservation,
            accountIsCurrent: true
        ) == .stopActiveReader)
        #expect(ReadAloudCarPlayDriver.invalidationDisposition(
            invalidatedObservationID: activeObservation,
            activeObservationID: activeObservation,
            accountIsCurrent: false
        ) == .ignoreStale)
    }

    @Test("disconnect cancels CarPlay source observers after detaching its host")
    func disconnectCancelsDriverSourceObservers() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/CarPlay/CarPlayPlaybackCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "func releaseCarPlayHost() async"))
        let end = try #require(source.range(of: "func accountDidChange() async", range: start.lowerBound..<source.endIndex))
        let release = source[start.lowerBound..<end.lowerBound]
        let hostRelease = try #require(release.range(of: "await owner.release(host: host)"))
        let cancel = try #require(release.range(of: "observationIDs.forEach(cancelInvalidationObservation)"))

        #expect(hostRelease.lowerBound < cancel.lowerBound)
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

    @Test("account replacement cancels playback observations")
    func accountChangeNotifiesDriver() async {
        let driver = FakeCarPlayPlaybackDriver()
        let coordinator = CarPlayPlaybackCoordinator(
            driver: driver,
            accountSnapshot: { CarPlayAccountSnapshot(userID: self.userID, generation: 1) },
            entitlementGate: { true }
        )

        await coordinator.accountDidChange()

        #expect(driver.calls == ["accountChange"])
    }
}
