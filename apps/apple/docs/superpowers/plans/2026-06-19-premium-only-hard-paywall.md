# Premium-only Hard Paywall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate app entry on a Pro entitlement (which includes an active 7-day trial); signed-in free users get a full-screen, non-dismissible paywall with a sign-out escape.

**Architecture:** A pure `AppGate` decision picks loading/signedOut/paywall/app from (authProbeComplete, isSignedIn, entitlement level). `RootView` reads the unified `EntitlementReconciler.level` (Observation-tracked) to drive it. Because the reconciler's *server* signal is never fed in production today, we add an `EntitlementService → reconciler.setServer` bridge. The paywall gate reuses the existing native `PaywallView`. `StoreKitIAPFlag` flips ON as the go-live switch.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, StoreKit 2, Better Auth (worker). Build via `swift test --package-path apps/apple/Packages/RishiBilling`; integrated gate via `xcodebuild` (orchestrator only).

**Key facts established from the codebase:**
- `EntitlementReconciler` (`apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementReconciler.swift`) is `@MainActor @Observable`; `level` = most-permissive union of `setOnDevice` (StoreKit, flag-gated) and `setServer`. `setServer` is currently called only in tests — production never feeds it.
- `EntitlementService` (actor) exposes `public nonisolated let currentLevel: AsyncStream<EntitlementLevel>` (yields cached value on init, then on every `setCached`/`refresh`/`clearCache`) and `func snapshot() -> EntitlementLevel`.
- `StoreKitIAPFlag.isEnabled` (same file, ~line 13-27): DEBUG reads UserDefaults `"rishi.iap.storekit.enabled"`; Release is hardcoded `false` (line 25).
- `RootView` (`apps/apple/rishi/rishi/RootView.swift`) signed-in branch is lines 110-122; it has `deps.entitlementReconciler` / `deps.entitlementService` (forwarders in `AppDependencies+Billing.swift`) and a `\.signOut` environment action (lines 78-88).
- `PaywallView(viewModel:feature:onDismiss:)` live init exists; `PaywallViewModel.make(services:)` exists (`apps/apple/rishi/rishi/Billing/PaywallViewModel+Make.swift`). `SignedInView` builds it via `PaywallViewModel.make(services: services)`.
- `EntitlementLevel` is `.free` / `.pro`, `Equatable`, `Sendable`.

---

### Task 1: `AppGate` pure routing decision

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/AppGate.swift`
- Test: `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Entitlements/AppGateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import RishiBilling

@Suite struct AppGateTests {
    @Test("loading until auth probe completes")
    func loadingWhileProbing() {
        #expect(AppGate.resolve(authProbeComplete: false, isSignedIn: false, level: .free) == .loading)
        #expect(AppGate.resolve(authProbeComplete: false, isSignedIn: true, level: .pro) == .loading)
    }

    @Test("signed out when probe done and no user")
    func signedOut() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: false, level: .free) == .signedOut)
    }

    @Test("signed-in free user gets the paywall")
    func paywallForFree() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, level: .free) == .paywall)
    }

    @Test("signed-in pro (incl. active trial) gets the app")
    func appForPro() {
        #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true, level: .pro) == .app)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/apple/Packages/RishiBilling --filter AppGateTests`
Expected: FAIL — "cannot find 'AppGate' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
/// Pure top-level routing decision for the app shell. Keeps the branch logic
/// out of the SwiftUI view so it is unit-testable.
public enum AppGate: Equatable, Sendable {
    case loading
    case signedOut
    case paywall
    case app

    /// - authProbeComplete: keychain session probe finished.
    /// - isSignedIn: a current user exists.
    /// - level: unified entitlement (server union on-device). `.pro` includes an active trial.
    public static func resolve(
        authProbeComplete: Bool,
        isSignedIn: Bool,
        level: EntitlementLevel
    ) -> AppGate {
        guard authProbeComplete else { return .loading }
        guard isSignedIn else { return .signedOut }
        return level == .pro ? .app : .paywall
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apps/apple/Packages/RishiBilling --filter AppGateTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/AppGate.swift apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Entitlements/AppGateTests.swift
git commit -m "feat(apple): add AppGate pure routing decision for hard paywall"
```

---

### Task 2: `EntitlementServerBridge` — feed the reconciler's server signal

**Why:** Production never calls `reconciler.setServer`, so `reconciler.level` ignores the worker's `has_pro`/trial state. The bridge pumps `EntitlementService.currentLevel` into `setServer`.

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementServerBridge.swift`
- Test: `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Entitlements/EntitlementServerBridgeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import RishiBilling

@Suite @MainActor struct EntitlementServerBridgeTests {
    @Test("pumps stream values into the reconciler server signal")
    func feedsServerSignal() async {
        let reconciler = EntitlementReconciler()
        #expect(reconciler.level == .free)

        var cont: AsyncStream<EntitlementLevel>.Continuation!
        let stream = AsyncStream<EntitlementLevel> { cont = $0 }
        cont.yield(.pro)
        cont.finish()

        await EntitlementServerBridge.run(levels: stream, into: reconciler)

        #expect(reconciler.level == .pro)
    }

    @Test("last value wins")
    func lastValueWins() async {
        let reconciler = EntitlementReconciler()
        var cont: AsyncStream<EntitlementLevel>.Continuation!
        let stream = AsyncStream<EntitlementLevel> { cont = $0 }
        cont.yield(.pro)
        cont.yield(.free)
        cont.finish()

        await EntitlementServerBridge.run(levels: stream, into: reconciler)

        #expect(reconciler.level == .free)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/apple/Packages/RishiBilling --filter EntitlementServerBridgeTests`
Expected: FAIL — "cannot find 'EntitlementServerBridge' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
/// Bridges the server-backed `EntitlementService` stream into the
/// `EntitlementReconciler`'s server signal. Without this, `reconciler.level`
/// only reflects on-device StoreKit (which is flag-gated) and ignores the
/// worker's has_pro / trial state. Runs for the app's lifetime.
public enum EntitlementServerBridge {
    @MainActor
    public static func run(
        levels: AsyncStream<EntitlementLevel>,
        into reconciler: EntitlementReconciler
    ) async {
        for await level in levels {
            reconciler.setServer(level)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apps/apple/Packages/RishiBilling --filter EntitlementServerBridgeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementServerBridge.swift apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Entitlements/EntitlementServerBridgeTests.swift
git commit -m "feat(apple): bridge EntitlementService server level into reconciler"
```

---

### Task 3: Flip `StoreKitIAPFlag` ON for release (go-live switch)

**Files:**
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementReconciler.swift` (the `#else` branch, currently line 25)

- [ ] **Step 1: Make the change**

In `enum StoreKitIAPFlag`, change the Release branch:

```swift
    #else
    public static let isEnabled: Bool = true
    #endif
```

(Leave the DEBUG branch — UserDefaults-backed — unchanged. DEBUG testers still toggle via `-rishi.iap.storekit.enabled`.)

- [ ] **Step 2: Run the package tests to confirm nothing breaks**

Run: `swift test --package-path apps/apple/Packages/RishiBilling`
Expected: PASS. (Existing reconciler/flag tests run under DEBUG and exercise the UserDefaults path, so they are unaffected by the Release constant.)

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementReconciler.swift
git commit -m "feat(apple): flip StoreKitIAPFlag on for release (paywall go-live)"
```

Note: this is a Release-only behavior change; it is verified by the integrated build (Task 6) and manual run, not by `swift test` (which runs DEBUG).

---

### Task 4: `PaywallGateView` (full-screen, non-dismissible, sign-out escape)

**Files:**
- Create: `apps/apple/rishi/rishi/Billing/PaywallGateView.swift`

(App-target SwiftUI view; verified by the integrated build in Task 6 and manual run — not unit-tested, since app-target views require `xcodebuild`.)

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import RishiBilling

/// Full-screen, non-dismissible paywall shown to signed-in users who are not
/// entitled (.free). Reuses the native `PaywallView`; the only ways out are a
/// successful purchase/trial (entitlement flips, RootView swaps to the app) or
/// the Sign out escape (so users are never trapped and App Review can exit).
struct PaywallGateView: View {
    let services: BootstrappedServices

    @Environment(\.signOut) private var signOut
    @State private var viewModel: PaywallViewModel?

    var body: some View {
        Group {
            if let viewModel {
                // onDismiss is a no-op: this is a root gate, not a sheet.
                PaywallView(viewModel: viewModel, feature: "Rishi Pro", onDismiss: {})
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Sign out", role: .cancel) { signOut() }
                .padding(.bottom, 8)
                .accessibilityIdentifier("paywallGate.signOut")
        }
        .task {
            if viewModel == nil {
                viewModel = PaywallViewModel.make(services: services)
            }
        }
    }
}
```

- [ ] **Step 2: Typecheck the file (best-effort)**

Run: `xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/Billing/PaywallGateView.swift`
Expected: may report "no such module 'RishiBilling'" in isolation (explicit-modules indexing) — that is acceptable; the integrated build in Task 6 is authoritative. Confirm there are no *syntax* errors.

- [ ] **Step 3: Commit**

```bash
git add apps/apple/rishi/rishi/Billing/PaywallGateView.swift
git commit -m "feat(apple): add full-screen PaywallGateView with sign-out escape"
```

---

### Task 5: Wire the gate into `RootView` + start the bridge

**Files:**
- Modify: `apps/apple/rishi/rishi/RootView.swift` (the `realBodyContent` branch at lines ~92-126, and the bootstrap `.task` at lines ~127-161)

- [ ] **Step 1: Replace the signed-in branch with the AppGate switch**

In `realBodyContent`, replace the `Group { if !authProbeComplete ... else if let user = currentUser { SignedInView(...) } else { signedOutView } }` body with a single AppGate-driven switch. Read `deps.entitlementReconciler.level` so Observation re-renders on entitlement changes:

```swift
Group {
    switch AppGate.resolve(
        authProbeComplete: authProbeComplete,
        isSignedIn: currentUser != nil,
        level: deps.entitlementReconciler.level
    ) {
    case .loading:
        #if canImport(UIKit)
        Color(.systemBackground).ignoresSafeArea().accessibilityHidden(true)
        #else
        Color.clear.ignoresSafeArea().accessibilityHidden(true)
        #endif
    case .signedOut:
        signedOutView
    case .paywall:
        PaywallGateView(services: deps.services!)
    case .app:
        SignedInView(
            services: deps.services!,
            user: currentUser!,
            selectedTabRaw: $selectedTabRaw,
            openBookIdRaw: $openBookIdRaw,
            onSignedOut: { currentUser = nil },
            onCacheUserId: { [deps] id in deps.cachedUserId = id }
        )
    }
}
```

(Keep the existing `.task { ... }` and onboarding `.fullScreenCover`/`.sheet` modifiers attached to this `Group` exactly as they are.)

- [ ] **Step 2: Start the server→reconciler bridge once, in the bootstrap task**

Inside the `.task` closure, after `bootstrapped = true` and before the auth probe, start the bridge (the stream is `nonisolated`, so no await needed to read it):

```swift
            // Feed the reconciler's server signal from EntitlementService for
            // the app's lifetime so the paywall gate reflects has_pro / trial.
            let entitlementLevels = deps.entitlementService.currentLevel
            let reconciler = deps.entitlementReconciler
            Task { @MainActor in
                await EntitlementServerBridge.run(levels: entitlementLevels, into: reconciler)
            }
```

(`RishiBilling` is already imported in RootView.swift. The existing `entitlementService.refresh()` call later in the task flows through the bridge into the reconciler.)

- [ ] **Step 3: Confirm the package tests still pass**

Run: `swift test --package-path apps/apple/Packages/RishiBilling`
Expected: PASS (RootView is app-target; this just confirms no package regressions).

- [ ] **Step 4: Commit**

```bash
git add apps/apple/rishi/rishi/RootView.swift
git commit -m "feat(apple): gate app entry on entitlement via AppGate + start server bridge"
```

---

### Task 6: Integrated build gate + manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run the canonical integrated build (orchestrator only — never a subagent)**

Run: `xcodebuild -project rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/rishi-dd-isolated build 2>&1 | grep -E "error:|\\*\\* BUILD (SUCCEEDED|FAILED) \\*\\*"`
Expected: `** BUILD SUCCEEDED **` (isolated derivedDataPath avoids the shared build.db lock if another session is building).

- [ ] **Step 2: Manual smoke test (DEBUG sim, launch args `-rishi.iap.storekit.enabled YES`, `-RishiUseStubReceiptVerifier YES`, StoreKit config Rishi.storekit)**

Verify:
1. Sign in as a fresh (free) user → the **PaywallGate** appears (not the library).
2. Tap a tier → Subscribe → entitlement flips and the **app** appears automatically.
3. From the gate, **Sign out** → returns to the sign-in screen (entitlement cleared).
4. Returning subscribed/trial user → goes straight to the app (no gate flash).

- [ ] **Step 3: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "test(apple): verify hard paywall gate end to end"
```

---

## Self-review

- **Spec coverage:** routing gate (Task 5) ✓; gate screen + sign-out escape (Task 4) ✓; reactivity/no-flash via reconciler observation + cache + bridge (Tasks 2,5) ✓; go-live flag (Task 3) ✓; trial = `.pro` (relies on existing plumbing; gate reads `.pro`) ✓; dropped upsell surfaces (nothing to build — N/A) ✓; toolbar overflow explicitly out of scope ✓; testing (Tasks 1,2 unit + Task 6 integrated/manual) ✓.
- **Placeholder scan:** none — every code step has full code.
- **Type consistency:** `AppGate.resolve(authProbeComplete:isSignedIn:level:)`, `EntitlementServerBridge.run(levels:into:)`, `PaywallGateView(services:)`, `EntitlementService.currentLevel`, `EntitlementReconciler.level/.setServer` all used consistently across tasks.
- **Known limitation:** `RootView` and `PaywallGateView` are app-target and not `swift test`-covered; their correctness is gated by the integrated `xcodebuild` (Task 6) plus manual smoke test. The decision/bridge logic they depend on IS unit-tested (Tasks 1-2).
