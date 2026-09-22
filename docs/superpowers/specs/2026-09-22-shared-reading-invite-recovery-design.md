# Shared Reading Invite Recovery Design

## Outcome

A shared-reading invite opens Rishi when it is installed, offers an explicit App Store path when it is not, and never leaves the original creator outside their own room. Invitation-email failures are visible and actionable instead of silent.

## Link handoff

New session links use `https://join.rishi.fidexa.org/sharing/session?token=…`. The join host serves the Apple association file and is declared by iOS and Catalyst associated-domain entitlements. The app accepts the join host plus the current `rishi.fidexa.org` host to preserve already-created invitations.

An incoming universal link from Mail or Messages opens Rishi directly when installed. When the OS opens the website instead, the join-host page is intentionally standalone: an explicit Open Rishi action, an App Store action, and no general-site navigation. This respects Safari’s same-domain Universal Link behavior while giving every fallback a clear next action.

## Session admission

The creator token is queued immediately after the create endpoint returns, not in the share sheet’s dismissal callback. The creator therefore enters the room as controller while the share sheet remains available. Starting remains a controller-only explicit action; participant state explains that it is waiting for the creator.

## Email delivery

The Worker remains the only component holding Resend credentials. It returns safe delivery counts, retryability, action text, and correlation identifiers. The compose UI displays these outcomes after every attempt. A valid key from the Resend account that has verified `fidexa.org` replaces the rejected production secret.

## Error handling and safety

No invite token is written to diagnostics, support copy, or public fallback HTML beyond the URL that the recipient already opened. Provider response bodies and credentials never reach the app. Existing `rishi.fidexa.org` links stay redeemable.

## Verification

Verify fresh universal-link metadata and fallback endpoints without using a real token, then build and launch the iPhone Simulator target. Verify creator admission and invite delivery only with a newly generated test session after the Resend secret is rotated.
