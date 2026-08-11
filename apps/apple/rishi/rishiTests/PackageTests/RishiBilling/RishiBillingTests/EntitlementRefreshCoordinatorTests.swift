@testable import rishi
import Foundation
import Testing

@Suite(.serialized)
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

    @Test("launch refresh hook runs for early account-change validation")
    func launchRefreshRunsForEarlyAccountChangeValidation() async {
        let harness = LockedEntitlementURLProtocolHarness()
        harness.configure(responses: [:])
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        provider.armBlockingReadBarrier(for: .launchCaller)
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
            provider.releaseReadBarrier(for: .launchCaller)
        }

        guard provider.waitForReadBarrier(for: .launchCaller) else {
            Issue.record("Launch validation did not reach the account-read barrier")
            return
        }
        provider.set("user-b")
        provider.releaseReadBarrier(for: .launchCaller)

        guard case .completed(let result) = await awaitEntitlementTaskValue(launch) else {
            Issue.record("Early launch validation did not complete within 5 seconds")
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
        provider.armBlockingReadBarrier(for: .launchCallerOne)
        provider.armBlockingReadBarrier(for: .launchCallerTwo)
        let launchSpy = LaunchRefreshSpy()
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
        let launchTwo = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer {
            launchOne.cancel()
            launchTwo.cancel()
            provider.releaseReadBarrier(for: .launchCallerOne)
            provider.releaseReadBarrier(for: .launchCallerTwo)
        }

        guard provider.waitForReadBarrier(for: .launchCallerOne),
              provider.waitForReadBarrier(for: .launchCallerTwo)
        else {
            Issue.record("Both launch callers did not reach early validation")
            return
        }
        provider.set("user-b")
        provider.releaseReadBarrier(for: .launchCallerOne)
        provider.releaseReadBarrier(for: .launchCallerTwo)

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("Early account-change callers did not complete within 5 seconds")
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
        provider.armBlockingReadBarrier(for: .launchCaller)
        let hookEntered = DispatchSemaphore(value: 0)
        let hookRelease = DispatchSemaphore(value: 0)
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
            provider.releaseReadBarrier(for: .launchCaller)
            hookRelease.signal()
        }

        guard provider.waitForReadBarrier(for: .launchCaller) else {
            Issue.record("Initial A launch caller did not reach validation")
            return
        }
        provider.set("user-b")
        provider.releaseReadBarrier(for: .launchCaller)
        guard hookEntered.wait(timeout: .now() + 5) == .success else {
            Issue.record("A early launch generation did not start reconciliation")
            return
        }

        provider.set("user-a")
        provider.armReadBarrier(for: .launchCallerTwo)
        let launchTwo = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCallerTwo) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        defer { launchTwo.cancel() }
        guard provider.waitForReadBarrier(for: .launchCallerTwo) else {
            Issue.record("Returning A launch caller did not reach validation")
            return
        }
        #expect(await launchSpy.callCount() == 1)
        hookRelease.signal()

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("A->B->A launch callers did not complete within 5 seconds")
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
        let foregroundGate = DispatchSemaphore(value: 0)
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
        guard harness.waitForRequestCount(1) else {
            foreground.cancel()
            foregroundGate.signal()
            Issue.record("Foreground request did not start within 5 seconds")
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

        guard harness.waitForRequestCount(2) else {
            Issue.record("Launch promotion did not start a second request")
            return
        }

        guard case .completed = await awaitEntitlementTaskValue(foreground) else {
            Issue.record("Foreground refresh task did not complete within 5 seconds")
            return
        }
        guard case .completed(let result) = await awaitEntitlementTaskValue(launch) else {
            Issue.record("Launch refresh task did not complete within 5 seconds")
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
        let responseGate = DispatchSemaphore(value: 0)
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let defaults = makeDefaults()
        let oldSnapshot = EntitlementSnapshot.trialActive(remainingCredits: 17)
        let oldData = seed(oldSnapshot, for: "user-a", in: defaults)
        let service = EntitlementService(
            workerClient: makeWorkerClient(harness: harness),
            defaults: defaults
        )
        await service.bindToUser(userId: "user-a")
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
        guard harness.waitForRequestCount(1) else {
            Issue.record("Entitlement request did not start within 5 seconds")
            return
        }
        provider.set("user-b")
        responseGate.signal()

        guard case .completed(let result) = await awaitEntitlementTaskValue(refresh) else {
            Issue.record("Entitlement refresh did not complete within 5 seconds")
            return
        }
        expectAccountChanged(result)
        #expect(await service.resolutionNow() == .unresolved)
        #expect(defaults.data(forKey: cacheKey(for: "user-a")) == oldData)
    }

    @Test("lateAccountAResponseDoesNotResetHydratedB: stale A work leaves B and both caches intact")
    func lateAccountAResponseDoesNotResetHydratedB() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let responseGate = DispatchSemaphore(value: 0)
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let defaults = makeDefaults()
        let snapshotA = EntitlementSnapshot.trialActive(remainingCredits: 11)
        let snapshotB = EntitlementSnapshot.trialActive(remainingCredits: 22)
        let dataA = seed(snapshotA, for: "user-a", in: defaults)
        let dataB = seed(snapshotB, for: "user-b", in: defaults)
        let service = EntitlementService(
            workerClient: makeWorkerClient(harness: harness),
            defaults: defaults
        )
        await service.bindToUser(userId: "user-a")
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
        guard harness.waitForRequestCount(1) else {
            Issue.record("Entitlement request did not start within 5 seconds")
            return
        }
        provider.set("user-b")
        await service.bindToUser(userId: "user-b")
        responseGate.signal()

        guard case .completed(let result) = await awaitEntitlementTaskValue(refresh) else {
            Issue.record("Entitlement refresh did not complete within 5 seconds")
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
        let responseGate = DispatchSemaphore(value: 0)
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let hookEntered = DispatchSemaphore(value: 0)
        let hookRelease = DispatchSemaphore(value: 0)
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
        guard harness.waitForRequestCount(1),
              provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2)
        else {
            Issue.record("Second launch caller did not join the first in-flight refresh")
            return
        }
        #expect(harness.requestCount == 1)
        provider.set("user-b")
        responseGate.signal()
        guard hookEntered.wait(timeout: .now() + 5) == .success else {
            Issue.record("Launch reconciliation hook did not start within 5 seconds")
            return
        }
        for _ in 0..<4 { hookRelease.signal() }

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(first),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(second)
        else {
            Issue.record("Coalesced callers did not complete within 5 seconds")
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
        let responseGate = DispatchSemaphore(value: 0)
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
        guard harness.waitForRequestCount(1) else {
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
        guard provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2) else {
            Issue.record("Second forced caller did not join the first in-flight refresh")
            return
        }
        #expect(harness.requestCount == 1)
        responseGate.signal()

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(first),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(second)
        else {
            Issue.record("Forced coalesced callers did not complete within 5 seconds")
            return
        }
        expectEqualResults(firstResult, secondResult)
        #expect(harness.requestCount == 1)
    }

    @Test("concurrent launch callers share one promoted generation")
    func concurrentLaunchCallersSharePromotedGeneration() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let firstGate = DispatchSemaphore(value: 0)
        let launchGate = DispatchSemaphore(value: 0)
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
        guard harness.waitForRequestRole(.initialForeground, at: 1) else {
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
            provider.releaseReadBarrier(for: .launchCallerOne)
            provider.releaseReadBarrier(for: .launchCallerTwo)
        }

        guard provider.waitForReadCount(for: .launchCallerOne, atLeast: 2),
              provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2)
        else {
            Issue.record("Both launch callers did not join the gated refresh")
            return
        }
        provider.armBlockingReadBarrier(for: .launchCallerTwo)
        harness.registerRequestRole(.promotedLaunch)
        firstGate.signal()

        guard harness.waitForRequestRole(.promotedLaunch, at: 2) else {
            Issue.record("Promoted launch request did not start")
            return
        }
        provider.armBlockingReadBarrier(for: .launchCallerOne)
        launchGate.signal()
        guard harness.waitForResponseCompletion(for: 2),
              provider.waitForReadBarrier(for: .launchCallerOne)
        else {
            Issue.record("First promoted launch generation did not finish and clear")
            return
        }
        provider.releaseReadBarrier(for: .launchCallerOne)
        provider.releaseReadBarrier(for: .launchCallerTwo)

        guard case .completed(let foregroundResult) = await awaitEntitlementTaskValue(foreground),
              case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("A shared launch caller did not complete within 5 seconds")
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
        let responseGate = DispatchSemaphore(value: 0)
        harness.configure(
            responses: [1: .success(paidSnapshot)],
            gates: [1: responseGate]
        )
        defer { harness.reset() }

        let provider = MutableUserProvider("user-a")
        let hookEntered = DispatchSemaphore(value: 0)
        let hookRelease = DispatchSemaphore(value: 0)
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
        guard harness.waitForRequestCount(1) else {
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
        guard provider.waitForReadCount(for: .launchCallerTwo, atLeast: 2) else {
            Issue.record("Second launch caller did not join the launch generation")
            return
        }

        responseGate.signal()
        guard hookEntered.wait(timeout: .now() + 5) == .success else {
            Issue.record("Launch reconciliation hook did not start")
            return
        }
        provider.set("user-b")
        for _ in 0..<4 { hookRelease.signal() }

        guard case .completed(let firstResult) = await awaitEntitlementTaskValue(launchOne),
              case .completed(let secondResult) = await awaitEntitlementTaskValue(launchTwo)
        else {
            Issue.record("Account-changed launch callers did not complete within 5 seconds")
            return
        }
        expectAccountChanged(firstResult)
        expectAccountChanged(secondResult)
        #expect(harness.requestCount == 1)
        #expect(await launchSpy.callCount() == 1)
    }

    @Test("launchPromotionReReadsNewerNonLaunchTask: launch waits for newer work and runs once")
    func launchPromotionReReadsNewerNonLaunchTask() async {
        let harness = LockedEntitlementURLProtocolHarness()
        let firstGate = DispatchSemaphore(value: 0)
        let newerForegroundGate = DispatchSemaphore(value: 0)
        let launchGate = DispatchSemaphore(value: 0)
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
            provider.releaseReadBarrier(for: .launchCaller)
            harness.reset()
        }

        harness.registerRequestRole(.initialForeground)
        let firstForeground = Task {
            await RefreshTestTaskContext.$role.withValue(.initialForeground) {
                await coordinator.refreshIfSignedIn(reason: .foreground)
            }
        }
        guard harness.waitForRequestRole(.initialForeground, at: 1) else {
            Issue.record("Initial foreground request did not start with its role")
            return
        }
        provider.armReadBarrier(for: .launchCaller)
        let launch = Task {
            await RefreshTestTaskContext.$role.withValue(.launchCaller) {
                await coordinator.refreshIfSignedIn(reason: .launch)
            }
        }
        guard provider.waitForReadBarrier(for: .launchCaller) else {
            Issue.record("Launch caller did not reach the in-flight wait")
            return
        }
        provider.armBlockingReadBarrier(for: .launchCaller)

        let newerForeground = Task {
            harness.markTaskStarted(.newerForeground)
            guard case .completed = await awaitEntitlementTaskValue(firstForeground) else {
                return nil
            }
            harness.registerRequestRole(.newerForeground)
            return await RefreshTestTaskContext.$role.withValue(.newerForeground) {
                await coordinator.refreshIfSignedIn(reason: .foreground)
            }
        }
        defer {
            firstForeground.cancel()
            newerForeground.cancel()
            launch.cancel()
        }
        guard harness.waitForTaskStart(.newerForeground) else {
            Issue.record("Newer foreground task did not install")
            return
        }
        firstGate.signal()
        guard harness.waitForRequestRole(.newerForeground, at: 2) else {
            Issue.record("Newer foreground request did not start with its role")
            return
        }
        guard provider.waitForReadBarrier(for: .launchCaller) else {
            Issue.record("Launch caller did not reach the re-read barrier")
            return
        }
        harness.registerRequestRole(.promotedLaunch)
        provider.releaseReadBarrier(for: .launchCaller)
        newerForegroundGate.signal()
        guard harness.waitForResponseCompletion(for: 2) else {
            Issue.record("Newer foreground response did not fully complete")
            return
        }
        guard harness.waitForRequestRole(.promotedLaunch, at: 3) else {
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
            Issue.record("Initial foreground task did not complete within 5 seconds")
            return
        }
        guard case .completed = await awaitEntitlementTaskValue(newerForeground) else {
            Issue.record("Newer foreground task did not complete within 5 seconds")
            return
        }
        guard case .completed(let result) = await awaitEntitlementTaskValue(launch) else {
            Issue.record("Promoted launch task did not complete within 5 seconds")
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

private final class GatedLaunchRefreshSpy: EntitlementLaunchRefresh, @unchecked Sendable {
    private let lock = NSLock()
    private let entered: DispatchSemaphore
    private let release: DispatchSemaphore
    private var calls = 0

    init(entered: DispatchSemaphore, release: DispatchSemaphore) {
        self.entered = entered
        self.release = release
    }

    func refreshOnDeviceEntitlementAtLaunch() async {
        lock.lock()
        calls += 1
        lock.unlock()
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private enum TimedEntitlementTaskResult<Value>: @unchecked Sendable {
    case completed(Value)
    case timedOut
}

private actor EntitlementTaskWaitState<Value> {
    private var didFinish = false
    private var taskWaiter: Task<Void, Never>?
    private var timeoutWaiter: Task<Void, Never>?

    func install(
        taskWaiter: Task<Void, Never>,
        timeoutWaiter: Task<Void, Never>
    ) {
        guard !didFinish else {
            taskWaiter.cancel()
            timeoutWaiter.cancel()
            return
        }
        self.taskWaiter = taskWaiter
        self.timeoutWaiter = timeoutWaiter
    }

    func finish(
        _ result: TimedEntitlementTaskResult<Value>,
        task: Task<Value, Never>,
        continuation: CheckedContinuation<TimedEntitlementTaskResult<Value>, Never>
    ) {
        guard !didFinish else {
            return
        }
        didFinish = true
        let taskWaiter = self.taskWaiter
        let timeoutWaiter = self.timeoutWaiter
        self.taskWaiter = nil
        self.timeoutWaiter = nil
        taskWaiter?.cancel()
        timeoutWaiter?.cancel()
        if case .timedOut = result {
            task.cancel()
        }
        continuation.resume(returning: result)
    }
}

private func awaitEntitlementTaskValue<Value>(
    _ task: Task<Value, Never>,
    timeout: Duration = .seconds(5)
) async -> TimedEntitlementTaskResult<Value> {
    await withCheckedContinuation { continuation in
        let state = EntitlementTaskWaitState<Value>()

        let taskWaiter: Task<Void, Never> = Task {
            await state.finish(
                .completed(await task.value),
                task: task,
                continuation: continuation
            )
        }
        let timeoutWaiter: Task<Void, Never> = Task {
            do {
                try await Task.sleep(for: timeout)
                await state.finish(
                    .timedOut,
                    task: task,
                    continuation: continuation
                )
            } catch {
                // The timeout waiter is cancelled when the task waiter wins.
            }
        }
        Task {
            await state.install(
                taskWaiter: taskWaiter,
                timeoutWaiter: timeoutWaiter
            )
        }
    }
}

private final class MutableUserProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var userId: String?
    private var readBarriers: [RefreshRole: ReadBarrier] = [:]
    private var readCounts: [RefreshRole: Int] = [:]
    private var readCountWaiters: [RefreshRole: [(expected: Int, signal: DispatchSemaphore)]] = [:]

    init(_ userId: String?) {
        self.userId = userId
    }

    var current: String? {
        lock.lock()
        let currentUserId = userId
        let role = RefreshTestTaskContext.role
        let barrier = role.flatMap { readBarriers[$0] }
        var signalsToFire: [DispatchSemaphore] = []
        if let role {
            let count = readCounts[role, default: 0] + 1
            readCounts[role] = count
            let waiters = readCountWaiters[role, default: []]
            readCountWaiters[role] = waiters.filter { waiter in
                guard count >= waiter.expected else { return true }
                signalsToFire.append(waiter.signal)
                return false
            }
        }
        let shouldBlock = barrier.map { !$0.consumed } ?? false
        if shouldBlock {
            barrier?.consumed = true
        }
        lock.unlock()
        signalsToFire.forEach { $0.signal() }
        if shouldBlock {
            barrier?.reached.signal()
        }
        if shouldBlock, barrier?.blocksRead == true {
            _ = barrier?.release.wait(timeout: .now() + 5)
        }
        return currentUserId
    }

    func set(_ userId: String?) {
        lock.lock()
        self.userId = userId
        lock.unlock()
    }

    func armReadBarrier(for role: RefreshRole) {
        lock.lock()
        readBarriers[role] = ReadBarrier(blocksRead: false)
        lock.unlock()
    }

    func armBlockingReadBarrier(for role: RefreshRole) {
        lock.lock()
        readBarriers[role] = ReadBarrier(blocksRead: true)
        lock.unlock()
    }

    func waitForReadBarrier(
        for role: RefreshRole,
        timeout: TimeInterval = 5
    ) -> Bool {
        lock.lock()
        let barrier = readBarriers[role]
        lock.unlock()
        guard let barrier,
              barrier.reached.wait(timeout: .now() + timeout) == .success
        else {
            return false
        }
        return true
    }

    func releaseReadBarrier(for role: RefreshRole) {
        lock.lock()
        let barrier = readBarriers[role]
        lock.unlock()
        barrier?.release.signal()
    }

    func waitForReadCount(
        for role: RefreshRole,
        atLeast expected: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        lock.lock()
        let count = readCounts[role, default: 0]
        if count >= expected {
            lock.unlock()
            return true
        }
        let signal = DispatchSemaphore(value: 0)
        readCountWaiters[role, default: []].append((expected, signal))
        lock.unlock()
        return signal.wait(timeout: .now() + timeout) == .success
    }

    private final class ReadBarrier: @unchecked Sendable {
        let blocksRead: Bool
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var consumed = false

        init(blocksRead: Bool) {
            self.blocksRead = blocksRead
        }
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
            Response(statusCode: statusCode, body: Data(#"{"error":"test failure"}"#.utf8))
        }
    }

    private let lock = NSLock()
    private let requestSignal = DispatchSemaphore(value: 0)
    private var responses: [Int: Response] = [:]
    private var gates: [Int: DispatchSemaphore] = [:]
    private var count = 0
    private var pendingRequestRoles: [RefreshRole] = []
    private var observedRoles: [Int: RefreshRole] = [:]
    private var startedTaskRoles: Set<RefreshRole> = []
    private var taskStartSignals: [RefreshRole: DispatchSemaphore] = [:]
    private var completedRequests: Set<Int> = []
    private var responseCompletionSignals: [Int: DispatchSemaphore] = [:]
    private var earlyRequestStarts: Set<Int> = []

    var protocolClass: URLProtocol.Type { LockedEntitlementURLProtocol.self }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func configure(
        responses: [Int: Response],
        gates: [Int: DispatchSemaphore] = [:]
    ) {
        LockedEntitlementURLProtocol.activate(self)
        lock.lock()
        self.responses = responses
        self.gates = gates
        count = 0
        pendingRequestRoles.removeAll()
        observedRoles.removeAll()
        startedTaskRoles.removeAll()
        taskStartSignals.removeAll()
        completedRequests.removeAll()
        responseCompletionSignals.removeAll()
        earlyRequestStarts.removeAll()
        lock.unlock()
    }

    func reset() {
        LockedEntitlementURLProtocol.deactivate(self)
        lock.lock()
        responses.removeAll()
        gates.removeAll()
        count = 0
        pendingRequestRoles.removeAll()
        observedRoles.removeAll()
        startedTaskRoles.removeAll()
        taskStartSignals.removeAll()
        completedRequests.removeAll()
        responseCompletionSignals.removeAll()
        earlyRequestStarts.removeAll()
        lock.unlock()
    }

    func registerRequestRole(_ role: RefreshRole) {
        lock.lock()
        pendingRequestRoles.append(role)
        lock.unlock()
    }

    func markTaskStarted(_ role: RefreshRole) {
        lock.lock()
        startedTaskRoles.insert(role)
        let signal = taskStartSignals[role]
        lock.unlock()
        signal?.signal()
    }

    func waitForTaskStart(
        _ role: RefreshRole,
        timeout: TimeInterval = 5
    ) -> Bool {
        lock.lock()
        if startedTaskRoles.contains(role) {
            lock.unlock()
            return true
        }
        let signal = taskStartSignals[role] ?? {
            let signal = DispatchSemaphore(value: 0)
            taskStartSignals[role] = signal
            return signal
        }()
        lock.unlock()
        return signal.wait(timeout: .now() + timeout) == .success
    }

    func waitForRequestCount(
        _ expected: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if requestCount >= expected { return true }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            _ = requestSignal.wait(timeout: .now() + min(remaining, 0.05))
        }
        return requestCount >= expected
    }

    func waitForRequestRole(
        _ role: RefreshRole,
        at requestNumber: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        guard waitForRequestCount(requestNumber, timeout: timeout) else { return false }
        lock.lock()
        let observedRole = observedRoles[requestNumber]
        lock.unlock()
        return observedRole == role
    }

    func observedRequestRoles() -> [RefreshRole] {
        lock.lock()
        defer { lock.unlock() }
        return observedRoles.keys
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { observedRoles[$0] }
    }

    func waitForResponseCompletion(
        for requestNumber: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        lock.lock()
        if completedRequests.contains(requestNumber) {
            lock.unlock()
            return true
        }
        let signal = responseCompletionSignals[requestNumber] ?? {
            let signal = DispatchSemaphore(value: 0)
            responseCompletionSignals[requestNumber] = signal
            return signal
        }()
        lock.unlock()
        return signal.wait(timeout: .now() + timeout) == .success
    }

    func requestStartedAfterResponseCompletion(
        request: Int,
        after previousRequest: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !earlyRequestStarts.contains(request) && completedRequests.contains(previousRequest)
    }

    fileprivate func handle(_ protocolObject: URLProtocol) {
        lock.lock()
        count += 1
        let requestNumber = count
        let gate = gates[requestNumber]
        let response = responses[requestNumber]
        if !pendingRequestRoles.isEmpty {
            observedRoles[requestNumber] = pendingRequestRoles.removeFirst()
        }
        if requestNumber == 3 && !completedRequests.contains(2) {
            earlyRequestStarts.insert(requestNumber)
        }
        lock.unlock()
        requestSignal.signal()

        if let gate, gate.wait(timeout: .now() + 5) == .timedOut {
            protocolObject.client?.urlProtocol(
                protocolObject,
                didFailWithError: URLError(.timedOut)
            )
            return
        }

        guard let response else {
            protocolObject.client?.urlProtocol(
                protocolObject,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        let httpResponse = HTTPURLResponse(
            url: protocolObject.request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        protocolObject.client?.urlProtocol(
            protocolObject,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        protocolObject.client?.urlProtocol(protocolObject, didLoad: response.body)
        protocolObject.client?.urlProtocolDidFinishLoading(protocolObject)
        lock.lock()
        completedRequests.insert(requestNumber)
        let completionSignal = responseCompletionSignals[requestNumber]
        lock.unlock()
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

    override func startLoading() {
        Self.activeLock.lock()
        let harness = Self.activeHarness
        Self.activeLock.unlock()
        harness?.handle(self)
    }

    override func stopLoading() {}
}
