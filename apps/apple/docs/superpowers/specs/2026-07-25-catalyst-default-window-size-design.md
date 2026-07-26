# Mac Catalyst Screenshot Window Size

## Goal

Make the Mac Catalyst app launch with a 1440×900 logical-point window, which produces the requested 2880×1800 pixel screenshot on a 2× Retina display.

## Design

Apply SwiftUI `Scene.defaultSize(width:height:)` to the existing `WindowGroup` only when compiling for Mac Catalyst. Keep iPhone and iPad behavior unchanged, and do not alter the existing PDF reader minimum-size clamp. The default size is a launch/restoration hint rather than a minimum restriction, so users can still resize the app normally.

## Scope

- Modify `apps/apple/rishi/rishi/rishiApp.swift`.
- Keep the existing `WindowGroup`, environment wiring, lifecycle handling, and commands intact.
- Add a Catalyst-only scene modifier using `width: 1440` and `height: 900`.
- Do not change screenshot assets, App Store Connect metadata, or PDF layout constants.

## Verification

- Build the Catalyst Debug target for `platform=macOS,variant=Mac Catalyst`.
- Inspect the diff to confirm the modifier is Catalyst-gated and no unrelated worktree changes were touched.

## Risks and mitigations

- A previously restored Catalyst window frame may take precedence over the default size; this is expected platform behavior. Reset the app/window state before capturing if necessary.
- Screenshot dimensions are physical pixels and depend on display scale. The requested 2880×1800 output requires a 2× capture surface; the app default is therefore 1440×900 points.
