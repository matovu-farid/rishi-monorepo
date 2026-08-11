# Paid users skip the free-trial intro popup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** Adversarial review loop complete — **PASS** (9 rounds, 0 open Critical/High/Medium issues).

**Goal:** Prevent the signed-in no-card free-trial intro popup from appearing for users whose fresh server entitlement is paid, while preserving the popup for unpaid and unknown entitlement states.

**Architecture:** Keep server refresh coordination in `EntitlementRefreshCoordinator`, but return its fresh `Result<EntitlementSnapshot, Error>?` so callers can distinguish a paid success from an unpaid success or failure. All concurrent calls for the same account coalesce onto one in-flight task, including force calls; a launch caller promotes only when the current task lacks launch reconciliation, and launch reconciliation remains inside that task. Keep the UI decision in a small pure `NoCardTrialIntroEligibility` predicate, then have `RootView` serialize the check on the main actor, refresh, re-check the account/seen state, apply the predicate, and only mark the intro seen on the presentation path.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, `xcodebuild`, server-owned `EntitlementSnapshot` from `GET /api/billing/me`.

---

## File map

- Create `apps/apple/rishi/rishi/Onboarding/NoCardTrialIntroEligibility.swift` — pure popup decision based only on the fresh coordinator result.
- Create `apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/NoCardTrialIntroEligibilityTests.swift` — focused behavior tests for paid, unpaid, and unknown/failure outcomes.
- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Entitlements/EntitlementRefreshCoordinator.swift` — return the fresh refresh result while coalescing same-account work and promoting launch reconciliation when required.
- Create `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/EntitlementRefreshCoordinatorTests.swift` — verify coordinator success/failure result propagation with a URLProtocol-backed WorkerClient.
- Modify `apps/apple/rishi/rishi/RootView.swift:13-25,232-241` — serialize the check on the main actor, refresh before presentation, suppress only successful paid snapshots, re-check the account/seen state, and mark seen only when showing.
- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Service/EntitlementService.swift:106-122` — validate the expected current account before applying or persisting a refresh response.
- Modify `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/EntitlementServiceTests.swift` — cover account-change invalidation, in-memory reset, and disk-cache preservation.
- Modify `apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/OnboardingUITests.swift` — source-order smoke test that protects the RootView integration boundary used by this target.

The Xcode project uses filesystem-synchronized groups, so new Swift files under the listed target directories are automatically included; no `project.pbxproj` edit is planned.

## Implementation order

1. Add and run the failing pure eligibility tests.
2. Add the minimal eligibility predicate and run those tests green.
3. Add and run failing coordinator result-propagation tests.
4. Change the coordinator API and run coordinator plus existing billing tests green.
5. Add the failing RootView integration assertion.
6. Wire the RootView refresh result into the predicate and run all focused tests.
7. Run the Apple build/test verification and independent implementation review.

## Task 1: Add the pure popup eligibility contract

**Files:**

- Create: `apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/NoCardTrialIntroEligibilityTests.swift`
- Create: `apps/apple/rishi/rishi/Onboarding/NoCardTrialIntroEligibility.swift`

- [ ] **Step 1: Write the failing tests.** Create the test file with exactly these cases:

```swift
@testable import rishi
import Foundation
import Testing

@Suite("No-card trial intro eligibility")
struct NoCardTrialIntroEligibilityTests {

    private struct TestError: Error {}

    private func paidPeriod() -> EntitlementSnapshot.PaidPeriod {
        EntitlementSnapshot.PaidPeriod(
            periodEndMs: 1_735_689_600_000,
            remainingNarrationSeconds: 60,
            remainingVoiceChatSeconds: 60
        )
    }

    @Test("paid reader and voice snapshots skip the popup")
    func paidSnapshotsSkipPopup() {
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.readerActive(paidPeriod()))
            ) == false
        )
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.voiceActive(paidPeriod()))
            ) == false
        )
    }

    @Test("unpaid snapshots retain the popup")
    func unpaidSnapshotsPresentPopup() {
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.trialActive(remainingCredits: 300))
            )
        )
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.trialExhausted)
            )
        )
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .success(.subscriptionExpired)
            )
        )
    }

    @Test("failed or unavailable refreshes retain the popup")
    func unknownRefreshPresentsPopup() {
        #expect(
            NoCardTrialIntroEligibility.shouldPresent(
                for: .failure(TestError())
            )
        )
        #expect(NoCardTrialIntroEligibility.shouldPresent(for: nil))
    }
}
```

- [ ] **Step 2: Run the focused test to verify RED.**

Run:

```bash
xcodebuild test \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:rishiTests/NoCardTrialIntroEligibilityTests
```

Expected: compilation fails because `NoCardTrialIntroEligibility` does not yet exist. If the command cannot start because full Xcode is unavailable, record that environment limitation and still inspect the compiler-visible test source before proceeding.

- [ ] **Step 3: Add the minimal predicate.** Create the production file:

```swift
import Foundation

enum NoCardTrialIntroEligibility {
    static func shouldPresent(
        for refreshResult: Result<EntitlementSnapshot, Error>?
    ) -> Bool {
        guard case .success(let snapshot) = refreshResult else { return true }
        return !snapshot.isPaidActive
    }
}
```

The predicate returns `false` only for a successful `readerActive` or `voiceActive` snapshot. It treats `nil` and every failure as unknown, which intentionally retains the popup.

- [ ] **Step 4: Run the focused test to verify GREEN.** Re-run the command from Step 2. Expected: all three tests pass.

- [ ] **Step 5: Commit the isolated behavior contract.**

```bash
git add apps/apple/rishi/rishi/Onboarding/NoCardTrialIntroEligibility.swift \
  apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/NoCardTrialIntroEligibilityTests.swift
git commit -m "test: define paid trial intro eligibility"
```

## Task 2: Return the fresh result from the coordinator

**Files:**

- Create: `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/EntitlementRefreshCoordinatorTests.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Entitlements/EntitlementRefreshCoordinator.swift:15-64`
- Modify: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Service/EntitlementService.swift:106-122`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/EntitlementServiceTests.swift`

- [ ] **Step 1: Write the failing coordinator tests.** Create a serialized test suite with a local URLProtocol so the tests verify the coordinator’s real `EntitlementService` path:

```swift
@testable import rishi
import Foundation
import Testing

@Suite(.serialized)
struct EntitlementRefreshCoordinatorTests {

    private struct NoOpLaunchRefresh: EntitlementLaunchRefresh {
        func refreshOnDeviceEntitlementAtLaunch() async {}
    }

    private actor LaunchRefreshSpy: EntitlementLaunchRefresh {
        private(set) var callCount = 0

        func refreshOnDeviceEntitlementAtLaunch() async {
            callCount += 1
        }
    }

    private final class MutableUserProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        init(_ value: String?) {
            self.value = value
        }

        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: String?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) static var statusCode = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var requestCount = 0
        nonisolated(unsafe) static var responseGates: [DispatchSemaphore] = []
        nonisolated(unsafe) static var waitingGates: [DispatchSemaphore] = []

        static func reset() {
            lock.lock()
            statusCode = 200
            body = Data()
            requestCount = 0
            responseGates = []
            waitingGates = []
            lock.unlock()
        }

        static func configure(statusCode: Int, body: Data, gatedResponses: Int = 0) {
            lock.lock()
            Self.statusCode = statusCode
            Self.body = body
            Self.requestCount = 0
            Self.responseGates = (0..<gatedResponses).map { _ in DispatchSemaphore(value: 0) }
            Self.waitingGates = []
            lock.unlock()
        }

        static func releaseResponses() {
            lock.lock()
            let gate = waitingGates.isEmpty ? nil : waitingGates.removeFirst()
            lock.unlock()
            gate?.signal()
        }

        static func waitForRequestCount(
            _ expected: Int,
            maxPolls: Int = 1_000
        ) async -> Bool {
            for _ in 0..<maxPolls {
                lock.lock()
                let count = requestCount
                lock.unlock()
                if count >= expected { return true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return false
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            lock.lock()
            requestCount += 1
            let statusCode = Self.statusCode
            let body = Self.body
            let gate = responseGates.isEmpty ? nil : responseGates.removeFirst()
            if let gate { waitingGates.append(gate) }
            lock.unlock()
            if let gate,
               gate.wait(timeout: .now() + .seconds(5)) == .timedOut
            {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeCoordinator(
        userProvider: MutableUserProvider = MutableUserProvider("user-123"),
        launchRefresh: any EntitlementLaunchRefresh = NoOpLaunchRefresh()
    ) -> EntitlementRefreshCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: URLSession(configuration: configuration),
            tokenProvider: StaticTokenProvider("test-token"),
            devBypassEnabled: false
        )
        let service = EntitlementService(
            workerClient: client,
            defaults: UserDefaults(suiteName: "test.billing.\(UUID().uuidString)")!
        )
        return EntitlementRefreshCoordinator(
            entitlementService: service,
            launchRefresh: launchRefresh,
            signedInUserIdProvider: { userProvider.get() }
        )
    }

    @Test("returns the fresh paid snapshot")
    func returnsFreshSnapshot() async {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.statusCode = 200
        MockURLProtocol.body = Data(
            #"{"state":"reader_active","periodEnd":1735689600000,"remainingNarrationSeconds":60,"remainingVoiceChatSeconds":60}"#.utf8
        )

        let result = await makeCoordinator().refreshIfSignedIn(reason: .signIn)
        guard let result else {
            Issue.record("Expected a result for a signed-in user")
            return
        }
        guard case .success(let snapshot) = result else {
            Issue.record("Expected a successful entitlement refresh")
            return
        }
        #expect(snapshot.isPaidActive)
    }

    @Test("returns refresh failures instead of hiding them")
    func returnsRefreshFailure() async {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.statusCode = 500
        MockURLProtocol.body = Data()

        let result = await makeCoordinator().refreshIfSignedIn(reason: .signIn)
        guard let result else {
            Issue.record("Expected a result for a signed-in user")
            return
        }
        guard case .failure = result else {
            Issue.record("Expected the coordinator to return the refresh failure")
            return
        }
    }
}
```

- [ ] **Step 1b: Extend the failing coordinator and service suites for ownership edge cases.** Add these named tests with synchronized URLProtocol gates and explicit assertions:
  - `launchRefreshPromotesNonLaunchWork`: hold a foreground response, request launch, release the gate, and assert the launch spy is called exactly once and the launch caller receives the promoted result.
  - `accountChangeInvalidatesResponseBeforeApply`: pre-seed a resolved user-A snapshot, switch the mutable provider to user B without binding B before releasing the response, and assert accountChanged failure, unresolved in-memory resolution, and the user-A disk payload still present.
  - `lateAccountAResponseDoesNotResetHydratedB`: pre-seed both accounts, bind A, switch the provider to B, bind B before releasing A's response, and assert accountChanged failure, unchanged user-B in-memory resolution, and both disk payloads still present.
  - `coalescedResultRevalidatesAccount`: have two same-account callers join one gated task, switch the provider before release, and assert both receive accountChanged rather than the paid snapshot.
  - `forcedCallersCoalesceInFlightWork`: start two concurrent force calls behind one request gate, release once, and assert the request counter is one and both callers receive the same result.
  - `launchPromotionReReadsNewerNonLaunchTask`: use two distinct response gates and the request counter to release the waited task, let a foreground caller install a newer non-launch task before the launch caller resumes, and assert the launch caller loops instead of overwriting it, waits for a launch-inclusive task, receives its result, and observes exactly one launch-spy call. Every request wait must assert await MockURLProtocol.waitForRequestCount(...) so a missing request fails within the bounded poll window.

- [ ] **Step 2: Run the coordinator tests to verify RED.**

Run:

```bash
xcodebuild test \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:rishiTests/EntitlementRefreshCoordinatorTests
```

Expected: compilation fails because `refreshIfSignedIn` currently returns `Void`, so the test cannot bind its result.

- [ ] **Step 3: Add account-safe response application to EntitlementService.** Define public enum EntitlementRefreshError: Error, Sendable { case accountChanged } and change the service method to accept an optional expected account and current-account validator:

```swift
@discardableResult
public func refreshSnapshot(
    expectedUserId: String,
    isCurrentUser: @Sendable @escaping () -> Bool
) async -> Result<EntitlementSnapshot, Error> {
    do {
        let snapshot = try await workerClient.send(BillingMeEndpoint())
        let accountStillMatches =
            boundUserId == expectedUserId && isCurrentUser()
        guard accountStillMatches else {
            if boundUserId == expectedUserId {
                latestResolution = .unresolved
                resolutionContinuation.yield(.unresolved)
            }
            return .failure(EntitlementRefreshError.accountChanged)
        }
        setCachedResolution(.resolved(snapshot, fetchedAt: Date()), fetchedAt: Date())
        return .success(snapshot)
    } catch {
        Log.event(
            "billing.entitlement_snapshot.refresh_failed",
            level: .warning,
            data: ["error": String(describing: error)]
        )
        return .failure(error)
    }
}
```

Require the validation context for all production service refreshes so no caller can accidentally apply an unscoped response. Update the existing direct service test call to bind a user and pass the matching validator. Add a service test with a pre-seeded resolved snapshot that changes a mutable current-user provider from user A to user B in the URLProtocol response handler, binds user B with a cached snapshot before releasing A's response, calls refreshSnapshot(expectedUserId: "user-a", isCurrentUser: { currentUser == "user-a" }), and asserts accountChanged failure, user-B in-memory resolution unchanged, and preservation of both persisted payloads.

- [ ] **Step 4: Change the coordinator minimally.** In `EntitlementRefreshCoordinator.swift`:

```swift
private struct InFlightRefresh {
    let id: UUID
    let userId: String
    let includesLaunchRefresh: Bool
    let task: Task<Result<EntitlementSnapshot, Error>, Never>
}

private var inFlightRefresh: InFlightRefresh?

public func refreshIfSignedIn(
    reason: RefreshReason = .foreground,
    force: Bool = false
) async -> Result<EntitlementSnapshot, Error>? {
    guard let requestedUserId = signedInUserIdProvider() else { return nil }

    while true {
        if let inFlightRefresh {
            if inFlightRefresh.userId == requestedUserId,
               (reason != .launch || inFlightRefresh.includesLaunchRefresh)
            {
                let result = await inFlightRefresh.task.value
                guard signedInUserIdProvider() == requestedUserId else {
                    return .failure(EntitlementRefreshError.accountChanged)
                }
                return result
            }

            let waitedID = inFlightRefresh.id
            _ = await inFlightRefresh.task.value
            guard signedInUserIdProvider() == requestedUserId else { return nil }

            // Re-read after suspension. If another caller installed a task,
            // loop and share/promote based on that newer task instead of
            // overwriting it.
            if let current = self.inFlightRefresh, current.id != waitedID {
                continue
            }
        }

        guard signedInUserIdProvider() == requestedUserId else { return nil }
        let refreshID = UUID()
        let userIdProvider = signedInUserIdProvider
        let task = Task<Result<EntitlementSnapshot, Error>, Never> {
            [entitlementService, launchRefresh, reason, userIdProvider, requestedUserId] in
            guard userIdProvider() == requestedUserId else {
                return .failure(EntitlementRefreshError.accountChanged)
            }
            await entitlementService.bindToUser(userId: requestedUserId)
            let result = await entitlementService.refreshSnapshot(
                expectedUserId: requestedUserId,
                isCurrentUser: { userIdProvider() == requestedUserId }
            )
            if reason == .launch {
                await launchRefresh.refreshOnDeviceEntitlementAtLaunch()
            }
            return result
        }
        inFlightRefresh = InFlightRefresh(
            id: refreshID,
            userId: requestedUserId,
            includesLaunchRefresh: reason == .launch,
            task: task
        )
        let result = await task.value
        if inFlightRefresh?.id == refreshID {
            inFlightRefresh = nil
        }
        guard signedInUserIdProvider() == requestedUserId else {
            return .failure(EntitlementRefreshError.accountChanged)
        }
        return result
    }
}
```

All same-account callers, including force callers, share the existing in-flight task; force therefore guarantees that a refresh is not skipped when no task is active, while avoiding duplicate concurrent generations. A launch caller waits for a non-launch task and then starts a launch-inclusive task; concurrent launch callers share that task. Launch StoreKit reconciliation remains inside the in-flight task, account changes invalidate both service application and coordinator return values, and existing callers that ignore the return value remain source-compatible.

- [ ] **Step 5: Run coordinator and existing billing tests.**

```bash
xcodebuild test \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:rishiTests/EntitlementRefreshCoordinatorTests \
  -only-testing:rishiTests/EntitlementServiceTests \
  -only-testing:rishiTests/SubscriptionPaywallStateTests
```

Expected: all selected tests pass; no existing caller requires a source change solely because it ignores the returned result.

- [ ] **Step 6: Commit the coordinator and service API change.**

```bash
git add apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Entitlements/EntitlementRefreshCoordinator.swift \
  apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Service/EntitlementService.swift \
  apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/EntitlementServiceTests.swift \
  apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/EntitlementRefreshCoordinatorTests.swift
git commit -m "feat: make entitlement refresh account-safe"
```

## Task 3: Gate the RootView popup on the fresh result

**Files:**

- Modify: `apps/apple/rishi/rishi/RootView.swift:13-25,232-241`
- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/OnboardingUITests.swift`

- [ ] **Step 1: Add the failing integration smoke test.** Add this test to `OnboardingUITests`:

```swift
@Test("Trial intro serializes and checks fresh entitlement before presenting")
func trialIntroChecksEntitlementBeforePresenting() throws {
    let source = try String(
        contentsOf: Self.rishiRoot().appendingPathComponent("rishi/RootView.swift"),
        encoding: .utf8
    )

    let inFlightGuard = try #require(
        source.range(of: "guard !noCardTrialIntroCheckInFlight else { return }")?.lowerBound
    )
    let refresh = try #require(
        source.range(of: "let refreshResult = await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn")?.lowerBound
    )
    let eligibility = try #require(
        source.range(of: "NoCardTrialIntroEligibility.shouldPresent(for: refreshResult)")?.lowerBound
    )
    let seen = try #require(
        source.range(of: "await deps.services!.onboarding.trialState.setHasSeenNoCardIntro(true, userId: user.id)")?.lowerBound
    )
    let postWriteAccountCheck = try #require(
        source.range(of: "guard case .signedIn(let presentedUser) = currentUserBox.state")?.lowerBound
    )
    let presentation = try #require(
        source.range(of: "showNoCardTrialIntro = true")?.lowerBound
    )

    #expect(inFlightGuard < refresh)
    #expect(refresh < eligibility)
    #expect(eligibility < seen)
    #expect(seen < postWriteAccountCheck)
    #expect(postWriteAccountCheck < presentation)
    #expect(seen < presentation)
    #expect(eligibility < presentation)
    #expect(source.contains("@State private var noCardTrialIntroCheckInFlight = false"))
    #expect(source.contains("defer { noCardTrialIntroCheckInFlight = false }"))
    #expect(source.contains("currentUser.id == user.id"))
    #expect(source.contains("await deps.services!.onboarding.trialState.setHasSeenNoCardIntro(false, userId: user.id)"))
}
```

- [ ] **Step 2: Run the onboarding tests to verify RED.**

```bash
xcodebuild test \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:rishiTests/OnboardingUITests
```

Expected: the new source-order test fails because RootView currently marks the intro seen and presents it without using the refresh result.

- [ ] **Step 3: Wire the fresh result into RootView.** Replace the current final body of `presentNoCardTrialIntroIfNeeded` with:

```swift
@State private var noCardTrialIntroCheckInFlight = false

@MainActor
private func presentNoCardTrialIntroIfNeeded(deps: AppDependencies) async {
    guard !noCardTrialIntroCheckInFlight else { return }
    noCardTrialIntroCheckInFlight = true
    defer { noCardTrialIntroCheckInFlight = false }

    guard case .signedIn(let user) = currentUserBox.state else { return }
    let alreadySeen = await deps.services!.onboarding.trialState.hasSeenNoCardIntro(userId: user.id)
    guard !alreadySeen else { return }

    let refreshResult = await deps.services!.billing.entitlementRefreshCoordinator.refreshIfSignedIn(
        reason: .signIn
    )
    guard case .signedIn(let currentUser) = currentUserBox.state,
          currentUser.id == user.id
    else { return }
    guard NoCardTrialIntroEligibility.shouldPresent(for: refreshResult) else { return }

    // Re-check after the await so another path that records the intro wins.
    guard !(await deps.services!.onboarding.trialState.hasSeenNoCardIntro(userId: user.id))
    else { return }
    await deps.services!.onboarding.trialState.setHasSeenNoCardIntro(true, userId: user.id)
    guard case .signedIn(let presentedUser) = currentUserBox.state,
          presentedUser.id == user.id
    else {
        await deps.services!.onboarding.trialState.setHasSeenNoCardIntro(false, userId: user.id)
        return
    }
    showNoCardTrialIntro = true
}
```

The full method must retain the existing signed-in and initial `alreadySeen` guards, with the new in-flight guard before the first await. Do not consult StoreKit state or `resolvedSnapshot` for this decision, because a failed fresh request must retain the popup fallback rather than trusting stale paid cache data. The main-actor gate prevents overlapping library-ready callbacks; the post-refresh account and seen re-check prevents showing for a signed-out/switched account or after another path records the intro.

- [ ] **Step 4: Run all focused tests.**

```bash
xcodebuild test \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:rishiTests/NoCardTrialIntroEligibilityTests \
  -only-testing:rishiTests/EntitlementRefreshCoordinatorTests \
  -only-testing:rishiTests/EntitlementServiceTests \
  -only-testing:rishiTests/SubscriptionPaywallStateTests \
  -only-testing:rishiTests/OnboardingUITests
```

Expected: all selected tests pass, including paid suppression, unpaid fallback, failure fallback, coordinator result propagation, and RootView ordering.

- [ ] **Step 5: Commit the UI integration.**

```bash
git add apps/apple/rishi/rishi/RootView.swift \
  apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/OnboardingUITests.swift
git commit -m "fix: skip trial intro for paid users"
```

## Task 4: Final verification and review

**Files:** No additional files; review the complete diff and current test/build output.

- [ ] **Step 1: Run the relevant app build.**

```bash
xcodebuild build \
  -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi \
  -sdk iphonesimulator \
  -configuration Debug
```

Expected: exit code 0. If full Xcode is unavailable, report the exact toolchain error and do not claim the build passed.

- [ ] **Step 2: Run the focused test suite again from a clean current checkout.** Use the Task 3 command and record the complete result.

- [ ] **Step 3: Inspect the final diff and verify scope.** Confirm that only the spec/plan documentation, coordinator result API, pure eligibility helper, RootView integration, and targeted tests changed; confirm no StoreKit, worker, database, migration, or paywall behavior changed.

- [ ] **Step 4: Dispatch an independent implementation reviewer.** Ask a fresh reviewer to inspect the final diff against the behavior contract, specifically checking stale-cache suppression on refresh failure, unpaid fallback, all coordinator call sites, and concurrent library-ready callbacks. Fix any Critical/High findings, then re-run the reviewer on the updated diff until there are zero open Critical/High findings.
- [ ] **Step 5: Commit the finalized planning artifacts before execution.**

```bash
git add docs/superpowers/specs/2026-08-11-paid-users-skip-trial-popup-design.md \
  docs/superpowers/plans/2026-08-11-paid-users-skip-trial-popup.md
git commit -m "docs: finalize paid trial popup plan"
```

## Adversarial review loop

Each round: review → log findings → update plan → re-review. The review must be independent and must verify claims against the current codebase, not only the prose in this plan.

### Research round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The approved design moved the seen-state write after an await without an account-scoped in-flight gate, allowing concurrent library-ready callbacks to present duplicates. | Updated the spec and plan to add a main-actor `noCardTrialIntroCheckInFlight` gate and a post-refresh seen-state re-check. |
| 2 | High | The coordinator’s original `force` branch can let concurrent forced callers start multiple refresh generations and clear each other’s in-flight state. | Updated the plan to use generation-tagged in-flight tasks; forced callers share a newly started generation and only the owning generation clears state. |
| 3 | High | Clearing the coordinator’s in-flight task before launch reconciliation ends opens a second refresh during the existing launch operation. | Kept launch reconciliation inside the task and return the captured server result after it completes. |
| 4 | Medium | A whole-file source-order assertion did not protect the seen-write order or concurrency guard. | Strengthened the assertion to check guard, refresh, eligibility, seen write, presentation order, account re-check, and reset behavior. |

**Round 1 result:** Re-review required. All identified High findings have concrete plan/spec resolutions; the updated artifacts must be independently re-reviewed.

### Plan round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The coordinator code block did not preserve safe forced-refresh coalescing under concurrent `force: true` calls. | Added `generation` to the in-flight task state, share-if-generation-changed logic, and conditional clearing. |
| 2 | High | The RootView code block could duplicate the popup because the initial seen check happened before the refresh await. | Added a main-actor in-flight gate, account identity re-check, and post-refresh seen re-check. |
| 3 | Medium | The integration smoke test was too broad to prove the relevant ordering. | Added exact ordering checks for the gate, refresh, eligibility, seen write, and presentation. |

**Round 1 result:** Re-review required until an independent reviewer confirms the updated API and concurrency fixes against the current codebase.

### Re-review round 2 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The account could change during the persisted seen-flag write, allowing the old account's popup to present after the write. | Added a post-write signed-in identity check before presentation and compensating clear of the old account's flag. |

**Round 2 result:** Re-review required; the post-write account-safety fix must be independently checked.

### Re-review round 3 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Coordinator work was not account-scoped, so a new account could share an old account's in-flight result. | Tag in-flight tasks with user ID, wait for mismatched-account work to finish, re-check the provider, and return an account-changed failure when the task starts stale. |
| 2 | High | A launch caller could coalesce onto a non-launch task and skip launch reconciliation. | Track whether each in-flight task includes launch reconciliation; launch callers promote non-launch work to a new generation, while concurrent launch callers share that generation. |
| 3 | Medium | An account could change during the seen-flag write, leaving the old account marked seen even though no popup was shown. | Compensate by clearing the old account's flag when the post-write identity check fails. |

**Round 3 result:** Re-review required; the updated account-scoped and launch-promotion fixes must be independently checked.

### Re-review round 4 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A launch caller could return a newer non-launch generation started by another caller and skip launch reconciliation. | Share a newer generation only when it includes launch reconciliation; otherwise continue the promotion loop. |
| 2 | High | Coordinator account tags did not fence the underlying service response/cache write during an account switch. | Pass expected user ID and a current-account validator into EntitlementService; reject before applying/persisting a mismatched response and return an account-change failure. |
| 3 | Medium | Same-account callers could return an in-flight result without rechecking the current account, and compensation could theoretically clear a newer write. | Recheck the provider before every shared/final result return; audit confirms RootView is the only production writer and its in-flight gate makes the compensating clear safe. |

**Round 4 result:** Re-review required; the account-safe service and launch-promotion changes must be independently checked.

### Re-review round 5 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A stale user-A response could reset user-B's already-hydrated in-memory entitlement state after an account switch. | Reset in-memory resolution only when the bound account still equals the expected account; preserve the current account's state and both disk caches. Add the bind-B-before-A-response test. |

**Round 5 result:** Re-review required; the account-scoped reset fix must be independently checked.

### Re-review round 6 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The race-test prose did not define the synchronization primitives, and the promotion scenario where a newer non-launch task appears before re-read was not explicitly covered. | Added a locked request-counting URLProtocol with response semaphores, mutable account provider, launch spy, named assertions, and a dedicated newer-non-launch promotion test. |

**Round 6 result:** Re-review required; the explicit synchronization/test coverage must be checked once more.

### Re-review round 7 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The gated URLProtocol aliased one semaphore across requests, request waits could hang indefinitely, and account-switch test requirements had conflicting expected states. | Use distinct mapped semaphores, bounded polling that returns Bool, and two explicit account-switch tests: expected-account reset versus hydrated-new-account preservation. |
| 2 | Medium | The plan lacked a documentation commit step. | Added an explicit commit of the spec and plan before execution. |

**Round 7 result:** Re-review required; the harness and artifact fixes must be independently checked.

### Re-review round 8 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The bounded request-count poll could still be followed by an unbounded semaphore wait when a response release was missed. | Add a five-second DispatchSemaphore timeout that fails the URLProtocol request with URLError.timedOut. |

**Round 8 result:** Re-review required; the timeout fix must be independently checked.

### Re-review round 9 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| — | — | Independent reviewer confirmed the timeout, bounded polling, account/launch tests, coordinator/service design, and file map. | No open issues. |

**Round 9 result:** PASS — 0 open Critical/High/Medium issues.

## Consumer / call-site audit

All current callers of `refreshIfSignedIn` were searched. They are in `RootView.swift`, `rishiApp.swift`, `SignedOutView.swift`, `SubscriptionsView.swift`, `LibraryTabView.swift`, `SettingsContent.swift`, `CatalystReaderWindow.swift`, `CurrentViewModifier.swift`, `ServiceGraphFactory.swift`, and `EntitlementAIGate.swift` (the last uses the coordinator only through its existing refresh side effect). They can ignore the new optional return value without behavior changes. Only `RootView.presentNoCardTrialIntroIfNeeded` consumes the result.

## Explicit out of scope

- StoreKit customer-entitlement reconciliation.
- Paywall and allowance presentation behavior.
- Worker billing response or subscription derivation.
- Database schema, migrations, or persisted entitlement formats.
- Changing the per-account “already seen” storage semantics beyond setting it only when the intro is actually shown.
