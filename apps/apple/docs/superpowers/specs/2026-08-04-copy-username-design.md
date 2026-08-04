# Copy Username Design

## Goal

Let signed-in users copy their existing username directly from the account UI.
The action must be discoverable, work on both Apple surfaces that expose the
account, and leave the username itself unchanged.

## Approved design

- iOS Settings shows a `doc.on.doc` button immediately beside a non-empty
  username in `AccountSection`.
- Mac Catalyst adds a `Copy Username` menu action with the same copy icon in
  the existing account menu. Menus do not provide a reliable inline row
  layout, so a labeled menu action is the native equivalent of the adjacent
  button.
- The copy action writes the exact username to the system clipboard.
- After a successful copy, the control briefly shows a checkmark and exposes
  `Copied` through accessibility. The normal copy icon returns automatically.
- No copy control is shown when the username is absent.

## Implementation

Use a small shared clipboard helper/action at the SwiftUI layer rather than
duplicating clipboard calls in each surface. The Apple target already imports
UIKit where needed, so `UIPasteboard.general` can be used for iOS and Mac
Catalyst without adding AppKit-specific branching. The helper remains
injectable for tests; production uses the system clipboard and tests capture
the copied value.

The iOS account row owns transient copied state for its button. The Catalyst
menu action uses the same helper and provides the menu label/identifier. The
username editor and Worker API remain unchanged.

## Verification

- Test that the copy action receives the exact username and that the action is
  omitted for a missing username.
- Test the accessibility label/identifier and copied-state transition where
  the existing SwiftUI test architecture permits it.
- Build the app for iOS Simulator and Mac Catalyst.
- Confirm the diff changes only Apple UI/test/spec files; no Worker or D1
  schema changes are needed.
