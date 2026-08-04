# Copy Username Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users copy an existing username from iOS Settings and Mac Catalyst's Account menu.

**Architecture:** Add one small injectable `UsernameClipboard` helper that writes through `UIPasteboard.general` on Apple platforms. `AccountSection` receives a copy closure and renders an inline copy button beside a non-empty username; `MacAccountMenuModel` receives a copy closure through its payload and exposes a native `Copy Username` menu action. Both surfaces own transient copied state so the copy icon changes to a checkmark briefly without changing account data.

**Tech Stack:** SwiftUI, Swift 6, UIKit `UIPasteboard`, Swift Testing, Xcode project target.

---

### Task 1: Add the clipboard seam and update the iOS account contract

**Files:**
- Create: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/UsernameClipboard.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/AccountSection.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/SettingsScreen.swift`

- [x] **Step 1: Add the injectable system clipboard helper**

Create a helper whose production action is platform-safe for both iOS and Mac Catalyst:

```swift
import Foundation

#if canImport(UIKit)
import UIKit
#endif

public enum UsernameClipboard {
    public static func copy(_ username: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = username
        #endif
    }
}
```

Keep the helper free of username validation or networking; it only writes the exact supplied string.

- [x] **Step 2: Thread a copy closure through `AccountSection` and `SettingsScreen`**

Add `onCopyUsername: (String) -> Void` with a default of `UsernameClipboard.copy` to both view initializers. `SettingsScreen` forwards the closure to `AccountSection`, allowing tests and future hosts to inject a recorder without touching the system clipboard.

- [x] **Step 3: Run the existing settings construction tests**

Run from the repository root:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/PackageTests/RishiSettings/RishiSettingsTests/SettingsScreenSmokeTests
```

Expected: the existing settings construction tests compile with the new defaulted closure and report only any already-known unrelated test-bundle failures.

### Task 2: Render and verify the iOS copy button

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/AccountSection.swift`
- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiSettings/RishiSettingsTests/SettingsScreenSmokeTests.swift`

- [x] **Step 1: Preserve editing while making the username row composable**

Replace the nested-button shape with an `HStack`: a plain-styled username edit button on the left/value area and a separate copy button on the right. Keep `settings-account-username` on the edit row and add `settings-account-username-copy` to the copy button.

- [x] **Step 2: Show the copy button only for a real username**

For a non-empty username, use a label like this:

```swift
Button {
    onCopyUsername(username)
    usernameCopied = true
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        usernameCopied = false
    }
} label: {
    Image(systemName: usernameCopied ? "checkmark" : "doc.on.doc")
}
.accessibilityLabel(usernameCopied ? "Username copied" : "Copy username")
.accessibilityIdentifier("settings-account-username-copy")
```

Use the existing typography/colors and do not render a copy control for `nil` or empty usernames. The edit action and “Not set” fallback remain available.

- [x] **Step 3: Add clipboard coverage for the copy action**

Add a UIKit-conditional smoke test that asserts `UsernameClipboard.copy` writes the exact username while restoring the prior pasteboard value afterward. UI event rendering remains covered by the iOS build because the repository has no SwiftUI inspection dependency.

### Task 3: Add the Catalyst account-menu copy action

**Files:**
- Modify: `apps/apple/rishi/rishi/Mac/MacAccountMenuModel.swift`
- Modify: `apps/apple/rishi/rishi/Mac/MacReaderPrefsMenuViewModel.swift`
- Modify: `apps/apple/rishi/rishi/Mac/RishiMenuCommands.swift`
- Modify: `apps/apple/rishi/rishiTests/Mac/MacAccountMenuModelTests.swift`

- [x] **Step 1: Add an injectable copy action to the Catalyst payload**

Add `onCopyUsername: () -> Void = {}` to `MacAccountMenuModel.Payload`. Add `usernameCopied` state and a `copyUsername()` method to the model that invokes the payload action only when a non-empty username exists, flips the transient state, and resets it after 1.5 seconds on `MainActor`.

- [x] **Step 2: Wire the production payload to `UsernameClipboard`**

In `MacReaderPrefsMenuViewModel.makeAccountPayload()`, capture the current non-empty username and set `onCopyUsername` to call `UsernameClipboard.copy`. Existing account payload refresh behavior remains unchanged.

- [x] **Step 3: Add the native menu item**

In `AccountMenuItems`, render this only for a non-empty username:

```swift
Button {
    account.copyUsername()
} label: {
    Label(
        "Copy Username",
        systemImage: account.usernameCopied ? "checkmark" : "doc.on.doc"
    )
}
```

The menu item uses the same accessibility wording and copy icon as iOS where the menu API permits it; existing edit/sign-out/delete actions remain untouched.

- [x] **Step 4: Test payload routing and missing-user behavior**

Add `MacAccountMenuModelTests` cases that inject a recorder, call `copyUsername()`, assert the action fires and copied state becomes true, and verify no action fires when the payload username is `nil`.

### Task 4: Verify, review, and commit

**Files:**
- Review all changed Apple source/test/spec/plan files.

- [x] **Step 1: Run focused Swift tests and builds**

Run:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:rishiTests/Mac/MacAccountMenuModelTests -only-testing:rishiTests/Mac/MacReaderPrefsMenuViewModelTests -only-testing:rishiTests/PackageTests/RishiSettings/RishiSettingsTests/SettingsScreenSmokeTests
xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/rishi-copy-username-ios-derived
xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /private/tmp/rishi-copy-username-catalyst-derived
```

Record any existing test-bundle failures separately from copy-username compile failures.

- [x] **Step 2: Review the final diff**

Run:

```bash
git diff --check
git status --short --branch
git diff --stat HEAD~1
```

Confirm only Apple UI/tests/spec/plan files changed; no Worker, D1, or migration files are included.

- [x] **Step 3: Commit the implementation**

```bash
git add apps/apple/docs/superpowers/plans/2026-08-04-copy-username.md apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/UsernameClipboard.swift apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/Account/AccountSection.swift apps/apple/rishi/rishi/Modules/RishiSettings/RishiSettings/UI/SettingsScreen.swift apps/apple/rishi/rishi/Mac/MacAccountMenuModel.swift apps/apple/rishi/rishi/Mac/MacReaderPrefsMenuViewModel.swift apps/apple/rishi/rishi/Mac/RishiMenuCommands.swift apps/apple/rishi/rishiTests/Mac/MacAccountMenuModelTests.swift apps/apple/rishi/rishiTests/PackageTests/RishiSettings/RishiSettingsTests/SettingsScreenSmokeTests.swift
git commit -m "feat: add copy username controls"

### Verification notes

- Final iOS application build: passed.
- Final Mac Catalyst application build: passed.
- Final focused test invocation exited 65 before tests ran because of unrelated pre-existing compile failures in `RishiVoice_PackageSmokeTests.swift` (`Core` not found) and stale `swift-realtime-openai/UITests/ConversationEventHandlingTests.swift` fixtures. The copy-username source files compiled without errors.
- `git diff --check`: passed. The two untracked Worker migration directories were pre-existing and intentionally excluded from this Apple-only change.

### Adversarial review

- Round 1 found stale copied-state timers, missing reset on username changes, and a small iOS touch target. All three were fixed.
- Round 2 found no remaining Critical, High, or Important issues. It noted only that unrelated account-menu payload refreshes can clear the transient Catalyst checkmark early, which is acceptable because the clipboard action and account data are unaffected.
```
