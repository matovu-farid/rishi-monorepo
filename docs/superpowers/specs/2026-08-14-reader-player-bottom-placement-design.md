# Reader read-aloud player bottom placement

> **Status:** Design approved — reserve the measured player height for EPUB content.

## Goal

Keep the read-aloud controls from covering the next visible EPUB paragraph when the player is shown at its default bottom position, without moving the controls themselves.

## Design

The read-aloud and voice controls remain a floating overlay at their current position. The overlay reports its measured height to `ReaderDestination`, which passes that value through `ReaderScreen` and `ReaderView` to the existing Readium `navigatorContentInset(_:)` delegate seam. The EPUB coordinator adds the measured height to its existing bottom inset and reapplies EPUB preferences when the measurement changes, so Readium recalculates the content region above the overlay. The controls retain their current internal bottom padding, horizontal margins, drag gesture, and clamping behavior.

This is intentionally a reader-layout fix, not a change to PDF layout or the player’s visual placement. The reservation is driven by the measured control height so it follows the active control state and device size.

## Scope

- Modify `apps/apple/rishi/rishi/Reader/ReaderAudioChromeOverlay.swift` to report its measured height.
- Modify `apps/apple/rishi/rishi/Reader/ReaderDestination.swift` to own the measured-height state and pass it to the reader while audio chrome is mounted.
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/UI/ReaderScreen.swift` and `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderView.swift` to thread the reservation to the coordinator and reapply preferences when it changes.
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/ReaderNavigatorCoordinator.swift` to add the measured height to the existing EPUB bottom inset and provide a pure calculation seam.
- Add a focused pure placement/reservation test in the existing reader audio chrome test file, plus source-level wiring assertions if needed by the target.
- Do not change PDF layout, EPUB typography, or player control layout.

## Acceptance criteria

1. With the player visible, the player remains at its current visual position.
2. The EPUB navigator receives a bottom reservation equal to its existing baseline inset plus the measured player height, so the next paragraph is not covered.
3. When the player is hidden, the reservation returns to zero and the existing reader layout is restored.
4. PDF readers and Catalyst readers do not receive the EPUB-only reservation.
5. Voice mode and read-aloud mode use the same reservation behavior.
6. Existing unrelated working-tree changes remain untouched.

## Verification

- Run the focused reader overlay test target if a pure placement test is added.
- Build the `rishi` iOS target with the repository's standard `xcodebuild` command.
- Inspect the final diff and run `git diff --check`.
