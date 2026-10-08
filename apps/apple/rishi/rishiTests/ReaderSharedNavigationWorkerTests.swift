@testable import rishi
#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import ReadiumShared
import UIKit

@Suite("Shared navigation worker", .serialized)
@MainActor
struct ReaderSharedNavigationWorkerTests {
    @MainActor
    private struct Fixture {
        let model: ReaderViewModel
        let coordinator: ReaderNavigatorCoordinator
        let locator: Locator
        let native: NativeOwner

        func request(_ revision: UInt64, position: Int? = nil) throws -> SharedReaderNavigationRequest {
            let target = locator.copy(locations: { $0.position = position ?? Int(revision) })
            return SharedReaderNavigationRequest(revision: revision, position: try target.jsonString())
        }

        func submit(_ request: SharedReaderNavigationRequest?, session: String = "room",
                    follower: Bool = true, onResult: ((SharedReaderNavigationResult) -> Void)? = nil) {
            coordinator.updateSharedNavigation(request: request, sessionID: session,
                                              isFollower: follower, onResult: onResult)
        }

        func activate() {
            coordinator.setSharedNavigationActive(true)
            coordinator.sharedNavigationNavigatorDidBecomeReady()
        }

        func drain() async {
            while let task = coordinator.sharedNavigation.flight?.task { await task.value }
        }
    }

    @MainActor
    private final class NativeOwner {
        let navigator = NSObject()
        let container = NSObject()
        var identity: SharedNavigationNativeIdentity {
            .init(navigator: ObjectIdentifier(navigator), container: ObjectIdentifier(container))
        }
    }

    private func fixture() async throws -> Fixture {
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let userID = UUID()
        let model = ReaderViewModel(
            book: Book(userId: userID, title: "Alice", formatType: .epub, fileURL: "Books/x/alice.epub"),
            userId: userID, documentURL: url, positionStore: InMemoryPositionStore(), debounceSeconds: 5)
        await model.load()
        let publication = try #require(model.publication)
        let link = try #require(publication.readingOrder.first)
        let href = try #require(RelativeURL(path: link.href))
        let locator = Locator(href: href, mediaType: link.mediaType ?? .xhtml)
        let coordinator = ReaderNavigatorCoordinator(viewModel: model)
        let native = NativeOwner()
        coordinator.sharedNavigation.nativeIdentityForTesting = native.identity
        return Fixture(model: model, coordinator: coordinator, locator: locator, native: native)
    }

    @Test("Latest input drains after uncancelable shared navigation; only current result delivers")
    func newestPendingRequestWins() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: true)
        var results: [UInt64] = []
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        f.submit(try f.request(1), onResult: { results.append($0.revision) })
        f.activate()
        await gate.waitForCalls(1)
        f.submit(try f.request(2), onResult: { results.append($0.revision) })
        f.submit(try f.request(3), onResult: { results.append($0.revision) })
        gate.releaseFirst()
        await f.drain()
        #expect(gate.positions == [1, 3])
        #expect(gate.peak == 1)
        #expect(results == [3])
    }

    @Test("Identical input refreshes callback and does not resubmit a consumed request")
    func callbackRefreshAndDedupe() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: true)
        var old = 0
        var current = 0
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        let request = try f.request(1)
        f.submit(request, onResult: { _ in old += 1 })
        f.activate()
        await gate.waitForCalls(1)
        f.submit(request, onResult: { _ in current += 1 })
        gate.releaseFirst()
        await f.drain()
        f.submit(request, onResult: { _ in current += 1 })
        f.coordinator.sharedNavigationNavigatorDidBecomeReady()
        await f.drain()
        #expect(old == 0)
        #expect(current == 1)
        #expect(gate.positions == [1])
    }

    @Test("Inactive inputs cannot drain; reappearance replays identical input", arguments: [false, true])
    func identicalInputReplaysAfterReappearance(holdFirst: Bool) async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: holdFirst)
        var results = 0
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        let request = try f.request(1)
        f.submit(request, onResult: { _ in results += 1 })
        f.activate()
        await gate.waitForCalls(1)
        if !holdFirst { await f.drain() }
        f.coordinator.setSharedNavigationActive(false)
        f.submit(request, onResult: { _ in results += 1 })
        f.coordinator.sharedNavigationNavigatorDidBecomeReady()
        #expect(gate.positions == [1])
        f.coordinator.setSharedNavigationActive(true)
        if holdFirst {
            #expect(gate.positions == [1])
            gate.releaseFirst()
        }
        await f.drain()
        #expect(gate.positions == [1, 1])
        #expect(gate.peak == 1)
        #expect(results == (holdFirst ? 1 : 2))
    }

    @Test("Retired owner suppresses old result and ignores all later updates")
    func terminalRetirement() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: true)
        var results = 0
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        f.submit(try f.request(1), onResult: { _ in results += 1 })
        f.activate()
        await gate.waitForCalls(1)
        f.coordinator.retireSharedNavigation()
        f.submit(try f.request(2), onResult: { _ in results += 1 })
        f.activate()
        gate.releaseFirst()
        await f.drain()
        #expect(results == 0)
        #expect(gate.positions == [1])
        #expect(f.coordinator.sharedNavigation.lifecycle == .retired)
    }

    @Test("Role loss fences old flight; role and session recovery drain current identity")
    func roleAndSessionFences() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: true)
        var results: [UInt64] = []
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        f.submit(try f.request(1), onResult: { results.append($0.revision) })
        f.activate()
        await gate.waitForCalls(1)
        f.submit(try f.request(1), follower: false)
        f.submit(try f.request(1), session: "new-room", onResult: { results.append($0.revision) })
        gate.releaseFirst()
        await f.drain()
        #expect(gate.positions == [1, 1])
        #expect(gate.peak == 1)
        #expect(results == [1])
        f.submit(try f.request(1, position: 2), session: "new-room")
        await f.drain()
        #expect(gate.positions == [1, 1, 2])
    }

    @Test("Early appearance and input wait for readiness; inactive readiness never authorizes work")
    func appearanceAndReadiness() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: false)
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        let reference = ReaderCoordinatorRef()
        reference.setSharedNavigationActive(true)
        reference.coordinator = f.coordinator
        f.coordinator.sharedNavigationNavigatorWillUpdate()
        f.submit(try f.request(1))
        f.coordinator.setSharedNavigationActive(reference.sharedNavigationIsActive)
        #expect(f.coordinator.sharedNavigation.flight == nil)
        f.coordinator.sharedNavigationNavigatorDidBecomeReady()
        await f.drain()
        #expect(gate.positions == [1])
        reference.setSharedNavigationActive(false)
        f.submit(try f.request(2))
        f.coordinator.sharedNavigationNavigatorDidBecomeReady()
        #expect(f.coordinator.sharedNavigation.flight == nil)
        reference.setSharedNavigationActive(true)
        await f.drain()
        #expect(gate.positions == [1, 2])
    }

    @Test("Container replacement invalidates delivery and replays behind old flight")
    func containerReplacement() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: true)
        var results = 0
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        f.submit(try f.request(1), onResult: { _ in results += 1 })
        f.activate()
        await gate.waitForCalls(1)
        let newContainer = NSObject()
        f.coordinator.sharedNavigationNavigatorWillUpdate()
        f.coordinator.sharedNavigation.nativeIdentityForTesting = .init(
            navigator: f.native.identity.navigator, container: ObjectIdentifier(newContainer))
        f.coordinator.sharedNavigationNavigatorDidBecomeReady()
        gate.releaseFirst()
        await f.drain()
        #expect(gate.positions == [1, 1])
        #expect(gate.peak == 1)
        #expect(results == 1)
    }

    @Test("Model replacement retires the passed owner even after the reference changes")
    func modelReplacement() async throws {
        let old = try await fixture()
        let replacement = try await fixture()
        let oldGate = NavigationGate(holdFirst: true)
        let newGate = NavigationGate(holdFirst: false)
        var oldResults = 0
        var newResults = 0
        old.coordinator.sharedNavigation.navigationForTesting = { await oldGate.navigate($0) }
        replacement.coordinator.sharedNavigation.navigationForTesting = { await newGate.navigate($0) }
        let reference = ReaderCoordinatorRef()
        reference.coordinator = old.coordinator
        reference.setSharedNavigationActive(true)
        old.submit(try old.request(1), onResult: { _ in oldResults += 1 })
        old.coordinator.sharedNavigationNavigatorDidBecomeReady()
        await oldGate.waitForCalls(1)
        reference.coordinator = replacement.coordinator
        ReaderView.dismantleUIViewController(UIViewController(), coordinator: old.coordinator)
        replacement.submit(try replacement.request(1), onResult: { _ in newResults += 1 })
        replacement.activate()
        await replacement.drain()
        oldGate.releaseFirst()
        await old.drain()
        #expect(oldResults == 0)
        #expect(newResults == 1)
        #expect(reference.coordinator === replacement.coordinator)
        #expect(old.coordinator.sharedNavigation.lifecycle == .retired)
        #expect(replacement.coordinator.sharedNavigation.lifecycle == .active)
    }

    @Test("Synchronous callback can submit another request or reactivate without overlap", arguments: [false, true])
    func callbackReentrancy(reactivate: Bool) async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: false)
        var results = 0
        let first = try f.request(1)
        let second = try f.request(2)
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        f.submit(first, onResult: { _ in
            results += 1
            if reactivate {
                f.coordinator.setSharedNavigationActive(false)
                f.submit(first, onResult: { _ in results += 1 })
                f.coordinator.setSharedNavigationActive(true)
            } else {
                f.submit(second, onResult: { _ in results += 1 })
            }
        })
        f.activate()
        await f.drain()
        #expect(results == 2)
        #expect(gate.positions == (reactivate ? [1, 1] : [1, 2]))
        #expect(gate.peak == 1)
    }

    @Test("Invalid/foreign positions fail once; native result reports observed locator")
    func validationAndObservation() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: false)
        var results: [SharedReaderNavigationResult] = []
        f.coordinator.sharedNavigation.navigationForTesting = { locator in
            _ = await gate.navigate(locator)
            f.model.didChangeLocation(f.locator, isProgrammatic: true)
            return false
        }
        let invalid = SharedReaderNavigationRequest(revision: 1, position: "invalid")
        f.submit(invalid, onResult: { results.append($0) })
        f.activate()
        await f.drain()
        f.submit(invalid, onResult: { results.append($0) })
        await f.drain()
        let foreign = Locator(href: try #require(RelativeURL(path: "not-in-book.xhtml")), mediaType: .xhtml)
        f.submit(.init(revision: 2, position: try foreign.jsonString()), onResult: { results.append($0) })
        await f.drain()
        f.submit(try f.request(3), onResult: { results.append($0) })
        await f.drain()
        #expect(results.map(\.outcome) == [
            .failed("The controller's reading position is invalid."),
            .failed("This shared position is not in the open book."),
            .failed("The reader could not open the controller's page.")])
        #expect(results.last?.observedLocator == f.locator)
        #expect(gate.positions == [3])
    }

    @Test("Scheduled stale work skips native go; callback retirement prevents queued work")
    func scheduledSupersessionAndRetiringCallback() async throws {
        let f = try await fixture()
        let gate = NavigationGate(holdFirst: false)
        f.coordinator.sharedNavigation.navigationForTesting = { await gate.navigate($0) }
        f.activate()
        f.submit(try f.request(1))
        let next = try f.request(3)
        f.submit(try f.request(2), onResult: { _ in
            f.submit(next)
            f.coordinator.retireSharedNavigation()
        })
        await f.drain()
        #expect(gate.positions == [2])
        #expect(f.coordinator.sharedNavigation.flight == nil)
    }
}

@MainActor
private final class NavigationGate {
    private let holdFirst: Bool
    private var release: CheckedContinuation<Void, Never>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var active = 0
    private(set) var positions: [Int] = []
    private(set) var peak = 0

    init(holdFirst: Bool) { self.holdFirst = holdFirst }

    func navigate(_ locator: Locator) async -> Bool {
        positions.append(locator.locations.position ?? -1)
        active += 1
        peak = max(peak, active)
        let ready = waiters.filter { $0.0 <= positions.count }
        waiters.removeAll { $0.0 <= positions.count }
        for (_, continuation) in ready { continuation.resume() }
        if holdFirst && positions.count == 1 {
            await withCheckedContinuation { release = $0 }
        }
        active -= 1
        return true
    }

    func waitForCalls(_ count: Int) async {
        guard positions.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func releaseFirst() {
        release?.resume()
        release = nil
    }
}
#endif
