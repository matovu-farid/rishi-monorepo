# Voice Controls Layout Design

## Goal

Make the reader voice-chat pill feel balanced and readable on narrow iPhone widths. Icon controls must not appear squeezed, the waveform must remain optically centered, and transient connection/activity text must not change the control row's geometry.

## Design

- Each icon button uses a 48×48 point content/touch frame with consistent horizontal padding.
- The control row uses a fixed-width center slot for the waveform. The slot is independent of status text and optional text-chat actions, so the waveform stays centered even when labels vary in length.
- Status text is presented as a short-lived notification-style toast above the pill. Connecting/listening/speaking/reconnecting updates replace the current toast and automatically disappear after a short delay.
- Persistent states remain in the toast until resolved: connection failures and the final-interval warning. The failure toast remains accessible and actionable through the existing end/retry flows.
- The pill keeps its existing glass background, drag behavior, accessibility identifiers, and actions.

## State and timing

`VoiceControlsView` derives a user-facing status message from `VoiceSessionState`. A monotonic generation token cancels stale dismissal tasks, so an older toast cannot hide a newer status. The view owns only presentation timing; session state remains the source of truth.

## Accessibility

Buttons retain their existing labels and identifiers. The toast is exposed as a single live status element, with the current message announced without making the entire pill one large control.

## Verification

- Construct the view across all activity phases and connecting statuses.
- Verify persistent failure and ending-soon messages remain available.
- Verify transient status presentation does not remove button identifiers or actions.
- Run the RishiVoice package UI tests and the full package suite.
