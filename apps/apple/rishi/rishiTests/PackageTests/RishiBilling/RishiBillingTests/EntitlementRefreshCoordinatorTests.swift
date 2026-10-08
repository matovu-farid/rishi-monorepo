@testable import rishi
import Foundation
import Testing
import Synchronization

@Suite(.serialized, .timeLimit(.minutes(1)))
struct EntitlementRefreshCoordinatorTests {

    private let paidSnapshot = EntitlementSnapshot.readerActive(
        EntitlementSnapshot.PaidPeriod(
            periodEndMs: 1_800_000_000_000,
            remainingNarrationSeconds: 900,
            remainingVoiceChatSeconds: 600
        )
    )

    @Test("returnsFreshSnapshot: paid success is returned")
    func returnsFreshSnapshot() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [1: .success(paidSnapshot)])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let coordinator = makeCoordinator(provider: provider, harness: harness)

        let result = await coordinator.refreshIfSignedIn()

        guard let result else {
            Issue.record("Expected a result for a signed-in user")
            return
        }
        switch result {
        case .success(let snapshot):
            #expect(snapshot == paidSnapshot)
        case .failure(let error):
            Issue.record("Expected a paid snapshot, got failure: \(error)")
        }
    }

    @Test("returnsRefreshFailure: failure is returned")
    func returnsRefreshFailure() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [1: .failure(statusCode: 500)])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let coordinator = makeCoordinator(provider: provider, harness: harness)

        let result = await coordinator.refreshIfSignedIn()

        guard let result else {
            Issue.record("Expected a result for a signed-in user")
            return
        }
        if case .success = result {
            Issue.record("Expected refresh failure")
        }
    }

    @Test("launch refresh hook runs when the server refresh fails")
    func launchRefreshRunsWhenRefreshFails() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [1: .failure(statusCode: 500)])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let launchSpy = LaunchRefreshSpy()
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )

        let result = await coordinator.refreshIfSignedIn(reason: .launch)

        guard let result else {
            Issue.record("Expected a result for a signed-in user")
            return
        }
        if case .success = result {
            Issue.record("Expected refresh failure")
        }
        #expect(harness.requestCount == 1)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("sign-in after launch still refreshes the signed-in account")
    func signInAfterLaunchStillRefreshes() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [
            1: .success(paidSnapshot),
            2: .success(paidSnapshot)
        ])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let launchSpy = LaunchRefreshSpy()
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )

        _ = await coordinator.refreshIfSignedIn(reason: .launch)
        _ = await coordinator.refreshIfSignedIn(reason: .signIn)

        #expect(harness.requestCount == 2)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("launch refresh hook runs for early account-change validation")
    func launchRefreshRunsForEarlyAccountChangeValidation() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [:])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        provider.scriptReads(["user-a", "user-b"], for: .launchCaller)
        provider.set("user-b")
        let launchSpy = LaunchRefreshSpy()
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )
        let launch = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCaller) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer {
            launch.cancel()
        }

        guard case .completed(let result) = await awaitEntitlementTaskValue(launch) else {
            Issue.record("Early launch validation did not complete")
            return
        }
        expectAccountChanged(result)
        #expect(harness.requestCount == 0)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("early account-change launch callers share one reconciliation")
    func earlyAccountChangeLaunchCallersShareOneReconciliation() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [:])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        provider.scriptReads(["user-a", "user-b"], for: .launchCallerOne)
        provider.scriptReads(["user-a", "user-b"], for: .launchCallerTwo)
        provider.set("user-b")
        let hookEntered = CoordinatorFixtureSignal()
        let hookRelease = CoordinatorFixtureSignal()
        let launchSpy = GatedLaunchRefreshSpy(entered: hookEntered, release: hookRelease)
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )
        let launchOne = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerOne) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer { launchOne.cancel(); hookRelease.signal() }
        guard await hookEntered.wait() else { Issue.record("First reconciliation did not enter"); return }
        let launchTwo = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer { launchTwo.cancel() }
        guard await provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2) else {
            Issue.record("Second caller did not reach early validation"); return
        }
        #expect(await launchSpy.callCount() == 1)
        hookRelease.signal()

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("Early account-change callers did not complete")
            return
        }
        expectAccountChanged(firstResult)
        expectAccountChanged(secondResult)
        #expect(harness.requestCount == 0)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("earlyLaunchGenerationReusedAfterAccountReturns: one hook while A generation is active")
    func earlyLaunchGenerationReusedAfterAccountReturns() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [:])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        provider.scriptReads(["user-a", "user-b"], for: .launchCaller)
        provider.set("user-b")
        let hookEntered = CoordinatorFixtureSignal()
        let hookRelease = CoordinatorFixtureSignal()
        let launchSpy = GatedLaunchRefreshSpy(
            entered: hookEntered,
            release: hookRelease
        )
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )
        let launchOne = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCaller) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer {
            launchOne.cancel()
            hookRelease.signal()
        }

        guard await hookEntered.wait() else {
            Issue.record("A early launch generation did not start reconciliation")
            return
        }

        provider.set("user-a")

        let launchTwo = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer { launchTwo.cancel() }
        guard await provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2) else {
            Issue.record("Returning A launch caller did not reach validation")
            return
        }
        #expect(await launchSpy.callCount() == 1)
        hookRelease.signal()

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("A->B->A launch callers did not complete")
            return
        }
        expectAccountChanged(firstResult)
        expectAccountChanged(secondResult)
        #expect(harness.requestCount == 0)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("launchRefreshPromotesNonLaunchWork: launch refresh runs exactly once")
    func launchRefreshPromotesNonLaunchWork() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let foregroundGate = CoordinatorFixtureSignal()
        let foregroundSnapshot = EntitlementSnapshot.trialActive(remainingCredits: 7)
        harness.configure(
            responses: [
                1: .success(foregroundSnapshot),
                2: .success(paidSnapshot)
            ],
            gates: [1: foregroundGate]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let launchSpy = LaunchRefreshSpy()
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )

        let foreground = Task {
            await coordinator.refreshIfSignedIn(reason: .foreground)
        }
        guard await harness.waitForRequestCount(1) else {
            foreground.cancel()
            foregroundGate.signal()
            Issue.record("Foreground request did not start")
            return
        }

        let launch = Task {
            await coordinator.refreshIfSignedIn(reason: .launch)
        }
        defer {
            foreground.cancel()
            launch.cancel()
            foregroundGate.signal()
        }
        foregroundGate.signal()

        guard await harness.waitForRequestCount(2) else {
            Issue.record("Launch promotion did not start a second request")
            return
        }

        guard case .completed = await awaitEntitlementTaskValue(foreground) else {
            Issue.record("Foreground refresh task did not complete")
            return
        }
        guard case .completed(let result) = await awaitEntitlementTaskValue(launch) else {
            Issue.record("Launch refresh task did not complete")
            return
        }

        guard let result else {
            Issue.record("Expected a launch result for a signed-in user")
            return
        }
        if case .failure(let error) = result {
            Issue.record("Expected launch refresh success, got failure: \(error)")
        }
        guard case .success(let snapshot) = result else {
            return
        }
        #expect(snapshot == paidSnapshot)
        #expect(harness.requestCount >= 2)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("accountChangeInvalidatesResponseBeforeApply: stale response is rejected and disk cache survives")
    func accountChangeInvalidatesResponseBeforeApply() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let responseGate = CoordinatorFixtureSignal()
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let defaults = makeDefaults()
        let oldSnapshot = EntitlementSnapshot.trialActive(remainingCredits: 17)
        _ = seed(oldSnapshot, for: "user-a", in: defaults)
        let service = EntitlementService(
            workerClient: makeWorkerClient(harness: harness),
            defaults: defaults
        )
        await service.bindToUser(userId: "user-a")
        let oldData = defaults.data(forKey: cacheKey(for: "user-a"))!
        let oldPayload = try! JSONDecoder().decode(CachedEntitlementSnapshotPayloadForTests.self, from: oldData)
        #expect(oldPayload.snapshot == oldSnapshot)
        #expect(oldPayload.cachedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let provider = MutableUserProvider("user-a")

        let refresh = Task {
            await service.refreshSnapshot(
                expectedUserId: "user-a",
                isCurrentUser: { provider.current == "user-a" }
            )
        }
        defer {
            refresh.cancel()
            responseGate.signal()
        }
        guard await harness.waitForRequestCount(1) else {
            Issue.record("Entitlement request did not start")
            return
        }
        provider.set("user-b")
        responseGate.signal()

        guard case .completed(let result) = await awaitEntitlementTaskValue(refresh) else {
            Issue.record("Entitlement refresh did not complete")
            return
        }
        expectAccountChanged(result)
        #expect(await service.resolutionNow() == .unresolved)
        #expect(defaults.data(forKey: cacheKey(for: "user-a")) == oldData)
    }

    @Test("lateAccountAResponseDoesNotResetHydratedB: stale A work leaves B and both caches intact")
    func lateAccountAResponseDoesNotResetHydratedB() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let responseGate = CoordinatorFixtureSignal()
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let defaults = makeDefaults()
        let snapshotA = EntitlementSnapshot.trialActive(remainingCredits: 11)
        let snapshotB = EntitlementSnapshot.trialActive(remainingCredits: 22)
        _ = seed(snapshotA, for: "user-a", in: defaults)
        _ = seed(snapshotB, for: "user-b", in: defaults)
        let service = EntitlementService(
            workerClient: makeWorkerClient(harness: harness),
            defaults: defaults
        )
        await service.bindToUser(userId: "user-a")
        let dataA = defaults.data(forKey: cacheKey(for: "user-a"))!
        let payloadA = try! JSONDecoder().decode(CachedEntitlementSnapshotPayloadForTests.self, from: dataA)
        #expect(payloadA.snapshot == snapshotA)
        #expect(payloadA.cachedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let provider = MutableUserProvider("user-a")

        let refresh = Task {
            await service.refreshSnapshot(
                expectedUserId: "user-a",
                isCurrentUser: { provider.current == "user-a" }
            )
        }
        defer {
            refresh.cancel()
            responseGate.signal()
        }
        guard await harness.waitForRequestCount(1) else {
            Issue.record("Entitlement request did not start")
            return
        }
        provider.set("user-b")
        await service.bindToUser(userId: "user-b")
        let dataB = defaults.data(forKey: cacheKey(for: "user-b"))!
        let payloadB = try! JSONDecoder().decode(CachedEntitlementSnapshotPayloadForTests.self, from: dataB)
        #expect(payloadB.snapshot == snapshotB)
        #expect(payloadB.cachedAt == Date(timeIntervalSince1970: 1_700_000_000))
        responseGate.signal()

        guard case .completed(let result) = await awaitEntitlementTaskValue(refresh) else {
            Issue.record("Entitlement refresh did not complete")
            return
        }
        expectAccountChanged(result)
        let resolution = await service.resolutionNow()
        guard case .resolved(let hydratedB, _) = resolution else {
            Issue.record("Expected user B to remain hydrated")
            return
        }
        #expect(hydratedB == snapshotB)
        #expect(defaults.data(forKey: cacheKey(for: "user-a")) == dataA)
        #expect(defaults.data(forKey: cacheKey(for: "user-b")) == dataB)
    }

    @Test("coalescedResultRevalidatesAccount: joined callers reject a result after account switch")
    func coalescedResultRevalidatesAccount() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let responseGate = CoordinatorFixtureSignal()
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let hookEntered = CoordinatorFixtureSignal()
        let hookRelease = CoordinatorFixtureSignal()
        let launchSpy = GatedLaunchRefreshSpy(
            entered: hookEntered,
            release: hookRelease
        )
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )
        let first = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerOne) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        let second = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer {
            first.cancel()
            second.cancel()
            responseGate.signal()
            for _ in 0..<4 { hookRelease.signal() }
        }
        guard await harness.waitForRequestCount(1),
              await provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2)
        else {
            Issue.record("Second launch caller did not join the first in-flight refresh")
            return
        }
        #expect(harness.requestCount == 1)
        provider.set("user-b")
        responseGate.signal()
        guard await hookEntered.wait() else {
            Issue.record("Launch reconciliation hook did not start")
            return
        }
        for _ in 0..<4 { hookRelease.signal() }

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(first),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(second)
        else {
            Issue.record("Coalesced callers did not complete")
            return
        }
        expectAccountChanged(firstResult)
        expectAccountChanged(secondResult)
        #expect(harness.requestCount == 1)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("forcedCallersCoalesceInFlightWork: concurrent force callers use one request")
    func forcedCallersCoalesceInFlightWork() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let responseGate = CoordinatorFixtureSignal()
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let coordinator = makeCoordinator(provider: provider, harness: harness)
        let first = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerOne) {
                await coordinator.refreshIfSignedIn(reason: .foreground, force: true)
            }
        }
        defer {
            first.cancel()
            responseGate.signal()
        }
        guard await harness.waitForRequestCount(1) else {
            Issue.record("First forced refresh request did not start")
            return
        }
        let second = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .foreground, force: true)
            }
        }
        defer {
            second.cancel()
        }
        guard await provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2) else {
            Issue.record("Second forced caller did not join the first in-flight refresh")
            return
        }
        #expect(harness.requestCount == 1)
        responseGate.signal()

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(first),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(second)
        else {
            Issue.record("Forced coalesced callers did not complete")
            return
        }
        expectEqualResults(firstResult, secondResult)
        #expect(harness.requestCount == 1)
    }

    @Test("concurrent launch callers share one promoted generation")
    func concurrentLaunchCallersSharePromotedGeneration() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let firstGate = CoordinatorFixtureSignal()
        let launchGate = CoordinatorFixtureSignal()
        harness.configure(
            responses: [
                1: .success(paidSnapshot),
                2: .success(paidSnapshot),
                3: .success(paidSnapshot)
            ],
            gates: [1: firstGate, 2: launchGate]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let launchSpy = LaunchRefreshSpy()
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )

        harness.registerRequestRole(.initialForeground)
        let foreground = Task {
            await RefreshTestTaskContext.$role.withValue(.initialForeground) {
                await coordinator.refreshIfSignedIn(reason: .foreground)
            }
        }
        defer { foreground.cancel() }
        guard await harness.waitForRequestRole(.initialForeground, at: 1) else {
            foreground.cancel()
            firstGate.signal()
            Issue.record("Initial foreground request did not start")
            return
        }

        let launchOne = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerOne) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        let launchTwo = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer {
            foreground.cancel()
            launchOne.cancel()
            launchTwo.cancel()
            firstGate.signal()
            launchGate.signal()
        }

        guard await provider.waitForReadCount(for: .launchCallerOne, atLeast: 2),
              await provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2)
        else {
            Issue.record("Both launch callers did not join the gated refresh")
            return
        }
        harness.registerRequestRole(.promotedLaunch)
        firstGate.signal()

        guard await harness.waitForRequestRole(.promotedLaunch, at: 2) else {
            Issue.record("Promoted launch request did not start")
            return
        }
        launchGate.signal()
        guard await harness.waitForResponseCompletion(for: 2)
        else {
            Issue.record("First promoted launch response did not finish")
            return
        }

        guard case .completed(let foregroundResult) = await awaitEntitlementTaskValue(foreground),
              case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("A shared launch caller did not complete")
            return
        }
        guard let foregroundResult, case .success = foregroundResult else {
            Issue.record("Expected foreground refresh success")
            return
        }
        expectEqualResults(firstResult, secondResult)
        #expect(harness.requestCount == 2)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("account change after shared launch reconciliation does not rerun hook")
    func accountChangeAfterSharedLaunchReconciliationDoesNotRerunHook() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let responseGate = CoordinatorFixtureSignal()
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let hookEntered = CoordinatorFixtureSignal()
        let hookRelease = CoordinatorFixtureSignal()
        let launchSpy = GatedLaunchRefreshSpy(
            entered: hookEntered,
            release: hookRelease
        )
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )
        let launchOne = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerOne) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        guard await harness.waitForRequestCount(1) else {
            launchOne.cancel()
            responseGate.signal()
            Issue.record("Initial launch request did not start")
            return
        }

        let launchTwo = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer {
            launchOne.cancel()
            launchTwo.cancel()
            responseGate.signal()
            for _ in 0..<4 { hookRelease.signal() }
        }
        guard await provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2) else {
            Issue.record("Second launch caller did not join the launch generation")
            return
        }

        responseGate.signal()
        guard await hookEntered.wait() else {
            Issue.record("Launch reconciliation hook did not start")
            return
        }
        provider.set("user-b")
        for _ in 0..<4 { hookRelease.signal() }

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("Account-changed launch callers did not complete")
            return
        }
        expectAccountChanged(firstResult)
        expectAccountChanged(secondResult)
        #expect(harness.requestCount == 1)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("launchWaitsForNewerForeground: launch waits for newer work and runs once")
    func launchWaitsForNewerForeground() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let firstGate = CoordinatorFixtureSignal()
        let newerForegroundGate = CoordinatorFixtureSignal()
        let launchGate = CoordinatorFixtureSignal()
        harness.configure(
            responses: [
                1: .success(paidSnapshot),
                2: .success(paidSnapshot),
                3: .success(paidSnapshot)
            ],
            gates: [
                1: firstGate,
                2: newerForegroundGate,
                3: launchGate
            ]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let launchSpy = LaunchRefreshSpy()
        let coordinator = makeCoordinator(
            provider: provider,
            harness: harness,
            launchRefresh: launchSpy
        )
        defer {
            firstGate.signal()
            newerForegroundGate.signal()
            launchGate.signal()
            harness.reset()
        }

        harness.registerRequestRole(.initialForeground)
        let firstForeground = Task {
            await RefreshTestTaskContext.$role.withValue(.initialForeground) {
                await coordinator.refreshIfSignedIn(reason: .foreground)
            }
        }
        defer { firstForeground.cancel() }
        guard await harness.waitForRequestRole(.initialForeground, at: 1) else {
            Issue.record("Initial foreground request did not start with its role")
            return
        }
        firstGate.signal()
        guard case .completed = await awaitEntitlementTaskValue(firstForeground) else {
            Issue.record("Initial foreground did not complete"); return
        }
        harness.registerRequestRole(.newerForeground)
        let newerForeground = Task {
            await RefreshTestTaskContext.$role.withValue(.newerForeground) {
                await coordinator.refreshIfSignedIn(reason: .foreground)
            }
        }
        defer { newerForeground.cancel() }
        guard await harness.waitForRequestRole(.newerForeground, at: 2) else {
            Issue.record("Newer foreground request did not start with its role"); return
        }
        let launch = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCaller) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer { launch.cancel() }
        guard await provider.waitForReadCount(for: .launchCaller, atLeast: 2) else {
            Issue.record("Launch did not validate the active newer foreground"); return
        }
        harness.registerRequestRole(.promotedLaunch)
        newerForegroundGate.signal()
        guard await harness.waitForResponseCompletion(for: 2) else {
            Issue.record("Newer foreground response did not fully complete")
            return
        }
        guard await harness.waitForRequestRole(.promotedLaunch, at: 3) else {
            Issue.record("Promoted launch request did not start with its role")
            return
        }
        guard harness.requestStartedAfterResponseCompletion(
            request: 3,
            after: 2
        ) else {
            Issue.record("Promoted launch request started before newer foreground completed")
            return
        }
        launchGate.signal()

        guard case .completed = await awaitEntitlementTaskValue(firstForeground) else {
            Issue.record("Initial foreground task did not complete")
            return
        }
        guard case .completed = await awaitEntitlementTaskValue(newerForeground) else {
            Issue.record("Newer foreground task did not complete")
            return
        }
        guard case .completed(let result) = await awaitEntitlementTaskValue(launch) else {
            Issue.record("Promoted launch task did not complete")
            return
        }
        guard let result else {
            Issue.record("Expected a launch result for a signed-in user")
            return
        }
        guard case .success(let snapshot) = result else {
            Issue.record("Expected launch promotion success")
            return
        }
        #expect(snapshot == paidSnapshot)
        #expect(harness.requestCount == 3)
        #expect(harness.observedRequestRoles() == [
            .initialForeground,
            .newerForeground,
            .promotedLaunch
        ])
        #expect(await launchSpy.callCount() == 1)
    }

    private func makeCoordinator(
        provider: MutableUserProvider,
        harness: LockedEntitlementURLProtocolHarness,
        launchRefresh: any EntitlementLaunchRefresh = NoOpLaunchRefresh()
    ) -> EntitlementRefreshCoordinator {
        let service = EntitlementService(workerClient: makeWorkerClient(harness: harness), defaults: makeDefaults())
        return EntitlementRefreshCoordinator(
            entitlementService: service,
            launchRefresh: launchRefresh,
            signedInUserIdProvider: { provider.current }
        )
    }

    private func makeWorkerClient(harness: LockedEntitlementURLProtocolHarness) -> WorkerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [harness.protocolClass]
        return WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: URLSession(configuration: configuration),
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.billing.coordinator.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    private func seed(
        _ snapshot: EntitlementSnapshot,
        for userId: String,
        in defaults: UserDefaults
    ) -> Data {
        let data = try! JSONEncoder().encode(
            CachedEntitlementSnapshotPayloadForTests(
                cachedAt: Date(timeIntervalSince1970: 1_700_000_000),
                snapshot: snapshot
            )
        )
        defaults.set(data, forKey: cacheKey(for: userId))
        return data
    }

    private func cacheKey(for userId: String) -> String {
        "billing.entitlement.snapshot.v1.\(userId)"
    }

    private func expectAccountChanged(
        _ result: Result<EntitlementSnapshot, Error>?
    ) {
        guard let result else {
            Issue.record("Expected accountChanged result, got nil")
            return
        }
        guard case .failure(let error) = result else {
            Issue.record("Expected accountChanged failure, got success")
            return
        }
        guard case EntitlementRefreshError.accountChanged = error else {
            Issue.record("Expected accountChanged, got \(error)")
            return
        }
    }

    private func expectAccountChanged(
        _ result: Result<EntitlementSnapshot, Error>
    ) {
        expectAccountChanged(Optional(result))
    }

    private func expectEqualResults(
        _ lhs: Result<EntitlementSnapshot, Error>?,
        _ rhs: Result<EntitlementSnapshot, Error>?
    ) {
        guard let lhs, let rhs else {
            Issue.record("Expected both callers to return results")
            return
        }
        switch (lhs, rhs) {
        case (.success(let left), .success(let right)):
            #expect(left == right)
        case (.failure(let left), .failure(let right)):
            #expect(String(describing: left) == String(describing: right))
        default:
            Issue.record("Expected callers to receive the same result")
        }
    }
}

private enum RefreshTestTaskContext {
    @TaskLocal static var role: RefreshRole?
}

private enum RefreshRole: String, Hashable, Sendable {
    case launchCaller
    case launchCallerOne
    case launchCallerTwo
    case initialForeground
    case newerForeground
    case promotedLaunch
}

private struct CachedEntitlementSnapshotPayloadForTests: Codable {
    let cachedAt: Date
    let snapshot: EntitlementSnapshot
}

private struct NoOpLaunchRefresh: EntitlementLaunchRefresh {
    func refreshOnDeviceEntitlementAtLaunch() async {}
}

private actor LaunchRefreshSpy: EntitlementLaunchRefresh {
    private var calls = 0

    func refreshOnDeviceEntitlementAtLaunch() async {
        calls += 1
    }

    func callCount() -> Int { calls }
}

private final class GatedLaunchRefreshSpy: EntitlementLaunchRefresh, Sendable {
    private let calls = Mutex(0)
    private let entered: CoordinatorFixtureSignal
    private let release: CoordinatorFixtureSignal
    init(entered: CoordinatorFixtureSignal, release: CoordinatorFixtureSignal) {
        self.entered = entered; self.release = release
    }
    func refreshOnDeviceEntitlementAtLaunch() async {
        calls.withLock { $0 += 1 }
        entered.signal()
        _ = await release.wait()
    }
    func callCount() -> Int { calls.withLock { $0 } }
}

private enum TimedEntitlementTaskResult<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
}

private final class EntitlementTaskWaitState<Value: Sendable>: Sendable {
    private struct State {
        var finished = false
        var continuation: CheckedContinuation<TimedEntitlementTaskResult<Value>, Never>?
        var waiter: Task<Void, Never>?
    }
    private let state = Mutex(State())
    func install(_ continuation: CheckedContinuation<TimedEntitlementTaskResult<Value>, Never>) {
        let canceled = state.withLock { state in
            if state.finished { return true }
            state.continuation = continuation; return false
        }
        if canceled { continuation.resume(returning: .timedOut) }
    }
    func install(_ waiter: Task<Void, Never>) {
        let finished = state.withLock { state in
            if state.finished { return true }
            state.waiter = waiter; return false
        }
        if finished { waiter.cancel() }
    }
    func finish(_ result: TimedEntitlementTaskResult<Value>) {
        let completion = state.withLock { state -> (CheckedContinuation<TimedEntitlementTaskResult<Value>, Never>?, Task<Void, Never>?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            let completion = (state.continuation, state.waiter)
            state.continuation = nil; state.waiter = nil
            return completion
        }
        completion.1?.cancel()
        completion.0?.resume(returning: result)
    }
}

private func awaitEntitlementTaskValue<Value: Sendable>(_ task: Task<Value, Never>) async -> TimedEntitlementTaskResult<Value> {
    let state = EntitlementTaskWaitState<Value>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            state.install(continuation)
            let waiter = Task { state.finish(.completed(await task.value)) }
            state.install(waiter)
        }
    } onCancel: {
        task.cancel()
        state.finish(.timedOut)
    }
}

private final class CoordinatorFixtureSignal: Sendable {
    private struct State {
        var count = 0
        var waiters: [UUID: (target: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    }
    private let state = Mutex(State())
    func signal() {
        let ready = state.withLock { state in
            state.count += 1
            let ready = state.waiters.filter { $0.value.target <= state.count }
            for id in ready.keys { state.waiters[id] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume(returning: true) }
    }
    func wait(for target: Int = 1) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = state.withLock { state in
                    if Task.isCancelled { return false }
                    if state.count >= target { return true }
                    state.waiters[id] = (target, continuation)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let continuation = self.state.withLock { $0.waiters.removeValue(forKey: id)?.continuation }
            continuation?.resume(returning: false)
        }
    }
}

private final class MutableUserProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var userId: String?
    private var readSignals: [RefreshRole: CoordinatorFixtureSignal] = [:]
    private var readScripts: [RefreshRole: [String?]] = [:]

    init(_ userId: String?) { self.userId = userId }

    var current: String? {
        let captured = lock.withLock { () -> (String?, CoordinatorFixtureSignal?) in
            let role = RefreshTestTaskContext.role
            var value = userId
            if let role, var script = readScripts[role], !script.isEmpty {
                value = script.removeFirst()
                readScripts[role] = script
            }
            let signal = role.map { role in
                if let signal = readSignals[role] { return signal }
                let signal = CoordinatorFixtureSignal(); readSignals[role] = signal; return signal
            }
            return (value, signal)
        }
        captured.1?.signal()
        return captured.0
    }

    func set(_ userId: String?) { lock.withLock { self.userId = userId } }
    /// The provider races between captured and current reads; it never blocks its caller actor.
    func scriptReads(_ values: [String?], for role: RefreshRole) {
        lock.withLock { readScripts[role] = values }
    }
    func waitForReadCount(for role: RefreshRole, atLeast expected: Int) async -> Bool {
        let signal = lock.withLock {
            if let signal = readSignals[role] { return signal }
            let signal = CoordinatorFixtureSignal(); readSignals[role] = signal; return signal
        }
        return await signal.wait(for: expected)
    }
}

private final class LockedEntitlementURLProtocolHarness: @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data

        static func success(_ snapshot: EntitlementSnapshot) -> Response {
            Response(
                statusCode: 200,
                body: try! JSONEncoder().encode(snapshot)
            )
        }

        static func failure(statusCode: Int) -> Response {
            Response(statusCode: statusCode, body: Data(#"{"error":{"code":"TEST_ENTITLEMENT_UNAVAILABLE","message":"test failure"}}"#.utf8))
        }
    }

    private let lock = NSLock()
    private let requestSignal = CoordinatorFixtureSignal()
    private var responses: [Int: Response] = [:]
    private var gates: [Int: CoordinatorFixtureSignal] = [:]
    private var count = 0
    private var pendingRequestRoles: [RefreshRole] = []
    private var observedRoles: [Int: RefreshRole] = [:]
    private var completedRequests: Set<Int> = []
    private var responseCompletionSignals: [Int: CoordinatorFixtureSignal] = [:]
    private var earlyRequestStarts: Set<Int> = []

    var protocolClass: URLProtocol.Type { LockedEntitlementURLProtocol.self }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func configure(
        responses: [Int: Response],
        gates: [Int: CoordinatorFixtureSignal] = [:]
    ) {
        LockedEntitlementURLProtocol.activate(self)
        lock.lock()
        self.responses = responses
        self.gates = gates
        count = 0
        pendingRequestRoles.removeAll()
        observedRoles.removeAll()
        completedRequests.removeAll()
        responseCompletionSignals.removeAll()
        earlyRequestStarts.removeAll()
        lock.unlock()
    }

    func reset() {
        LockedEntitlementURLProtocol.deactivate(self)
        lock.lock()
        let releasedGates = Array(gates.values)
        responses.removeAll()
        gates.removeAll()
        count = 0
        pendingRequestRoles.removeAll()
        observedRoles.removeAll()
        completedRequests.removeAll()
        responseCompletionSignals.removeAll()
        earlyRequestStarts.removeAll()
        lock.unlock()
        releasedGates.forEach { $0.signal() }
    }

    func registerRequestRole(_ role: RefreshRole) {
        lock.lock()
        pendingRequestRoles.append(role)
        lock.unlock()
    }

    func waitForRequestCount(_ expected: Int) async -> Bool {
        await requestSignal.wait(for: expected)
    }
    func waitForRequestRole(_ role: RefreshRole, at requestNumber: Int) async -> Bool {
        guard await waitForRequestCount(requestNumber) else { return false }
        return lock.withLock { observedRoles[requestNumber] == role }
    }

    func observedRequestRoles() -> [RefreshRole] {
        lock.lock()
        defer { lock.unlock() }
        let roles: [RefreshRole] = observedRoles.keys.sorted().compactMap { observedRoles[$0] }
        return roles
    }

    func waitForResponseCompletion(for requestNumber: Int) async -> Bool {
        let capture = lock.withLock { () -> (Bool, CoordinatorFixtureSignal) in
            let signal = responseCompletionSignals[requestNumber] ?? CoordinatorFixtureSignal()
            responseCompletionSignals[requestNumber] = signal
            return (completedRequests.contains(requestNumber), signal)
        }
        if capture.0 { return true }
        return await capture.1.wait()
    }

    func requestStartedAfterResponseCompletion(
        request: Int,
        after previousRequest: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !earlyRequestStarts.contains(request) && completedRequests.contains(previousRequest)
    }

    fileprivate func handle(_ protocolObject: URLProtocol) async {
        let capture = lock.withLock { () -> (Int, CoordinatorFixtureSignal?, Response?) in
            count += 1
            let requestNumber = count
            if !pendingRequestRoles.isEmpty { observedRoles[requestNumber] = pendingRequestRoles.removeFirst() }
            if requestNumber == 3 && !completedRequests.contains(2) { earlyRequestStarts.insert(requestNumber) }
            return (requestNumber, gates[requestNumber], responses[requestNumber])
        }
        requestSignal.signal()
        if let gate = capture.1, !(await gate.wait()) { return }
        guard !Task.isCancelled else { return }
        guard let response = capture.2 else {
            protocolObject.client?.urlProtocol(protocolObject, didFailWithError: URLError(.badServerResponse)); return
        }
        let httpResponse = HTTPURLResponse(url: protocolObject.request.url!, statusCode: response.statusCode,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        protocolObject.client?.urlProtocol(protocolObject, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        protocolObject.client?.urlProtocol(protocolObject, didLoad: response.body)
        protocolObject.client?.urlProtocolDidFinishLoading(protocolObject)
        let completionSignal = lock.withLock {
            completedRequests.insert(capture.0)
            return responseCompletionSignals[capture.0]
        }
        completionSignal?.signal()
    }

}

private final class LockedEntitlementURLProtocol: URLProtocol, @unchecked Sendable {
    private static let activeLock = NSLock()
    private nonisolated(unsafe) static var activeHarness: LockedEntitlementURLProtocolHarness?

    fileprivate static func activate(_ harness: LockedEntitlementURLProtocolHarness) {
        activeLock.lock()
        activeHarness = harness
        activeLock.unlock()
    }

    fileprivate static func deactivate(_ harness: LockedEntitlementURLProtocolHarness) {
        activeLock.lock()
        if activeHarness === harness { activeHarness = nil }
        activeLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private struct LoadingState {
        var task: Task<Void, Never>?
        var stopped = false
    }
    private let running = Mutex(LoadingState())
    override func startLoading() {
        let harness = Self.activeLock.withLock { Self.activeHarness }
        let task = Task { [self] in
            if let harness { await harness.handle(self) }
        }
        let stopped = running.withLock { state in
            if state.stopped { return true }
            state.task = task
            return false
        }
        if stopped { task.cancel() }
    }
    override func stopLoading() {
        let task = running.withLock { state in
            state.stopped = true
            let task = state.task
            state.task = nil
            return task
        }
        task?.cancel()
    }
}
