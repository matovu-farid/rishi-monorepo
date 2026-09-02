# Rishi Reader Social Groups — Product Specification

**Date:** 2026-09-03
**Status:** Approved product direction; implementation-ready draft
**Related map:** [Wayfinder Map: Rishi Reader Social Network](https://github.com/matovu-farid/rishi-monorepo/issues/261)
**Decision record:** [Group-only social graph and interaction boundaries](https://github.com/matovu-farid/rishi-monorepo/issues/264)

## Goal

Make Rishi a reader-focused social app built around persistent Reading Groups and small, voice-first Reading Sessions, while keeping the first release structured, private by default, and low-friction for members.

## Product language

- **Reading Group:** the persistent container with members, admins, a rotating reading program, and reading-cycle history.
- **Reading Cycle:** one book selected by the group, including its sessions and history.
- **Reading Session:** a live group of no more than five people reading the current book together.
- **Controller:** the participant whose reader position is authoritative for the session. The existing Apple shared-reading implementation uses this role.
- **Book Pick:** the book selected by an authorized group admin for the next Reading Cycle.
- **Organizer:** the owner or an admin who manages the Reading Group.

## Guiding principles

1. Minimize friction for readers. Joining should do the useful work automatically.
2. Groups are controlled reading spaces, not general social networks.
3. Voice is the primary communication medium.
4. Rishi should reuse the existing Apple shared-reading transport and reader synchronization instead of creating a second session technology.
5. Safety, legal, and reliability requirements may require an explicit step.
6. Rishi-hosted copies are the platform boundary. Rishi does not control personal or external copies.

## Discovery and membership

- Users search only explicitly public Reading Groups.
- Private groups are reachable through an exact group identifier or an invitation.
- Public groups show only name, current book, schedule, and member count before approval.
- Admin and member identities remain hidden until membership is approved.
- Every public-group request requires admin approval.
- A user may join a group before a book is selected.
- Once approved into a group with a current book, the user is automatically enrolled in the next available Reading Session.
- If no book is selected, the user remains a member and is automatically enrolled when the next cycle begins.
- Approved members may see one another’s usernames and minimal profiles inside the group.
- There is no global user directory, follow graph, unsolicited direct messaging, or user-to-user discovery.

## Group administration

- A group has one owner and may have multiple admins.
- All admins can approve or reject membership requests, remove members, choose books, and manage session membership.
- Only the owner can add or remove admins, transfer ownership, or delete the group.
- Any admin may remove a member immediately from the group and its sessions.
- Removing a member ends group/session participation but does not delete a book already saved in that member’s personal Rishi library.

## Books and reading cycles

- A group has one current book at a time.
- Only admins choose the next book in the first release.
- The book must already be imported into the selecting admin’s Rishi library.
- Choosing a new book starts a new Reading Cycle and preserves the previous cycle’s history.
- A new book cannot disrupt an active session for the previous book.
- Existing sessions for the previous book may finish, but they accept no new participants.
- New assignments use only the new current book.
- A group may have multiple sessions for the same current book, but not sessions for different books concurrently.

## Session formation and membership

- A Reading Group may have more than five members.
- Each Reading Session has a hard server-enforced maximum of five participants.
- When more than five members choose the same book, Rishi automatically creates additional sessions of up to five.
- Members choose an available session when possible.
- Members who do not choose are assigned to the first available session.
- A member belongs to only one session for a given book cycle at a time.
- A member may leave and later join another session for that cycle.
- Members may join an active session while it has fewer than five participants.
- A full session directs the member to another session or triggers creation of one.
- Each session has its own schedule, initially copied from the group schedule and independently adjustable.
- Any assigned member may start a session at or after its scheduled time. Admins may start it early.
- The session’s existing controller/sharer model remains in place. Controller transfer and controller departure behavior must be made consistent across the Apple client and Worker before release.

## Low-friction book access

- Joining a Reading Session automatically saves the shared book to the member’s Rishi library.
- No separate “Save to My Library” confirmation is required.
- Leaving the group or session does not delete the saved personal library copy.
- The group/session share link is revoked when access should end; this does not reach into copies outside Rishi.
- Import and duplicate prevention remain idempotent and hash-based. A book already present for the user is reused rather than imported again.

## Voice-first session behavior

The existing Apple rules are authoritative:

- Sessions are audio-only; there is no video.
- Voice is the primary communication channel.
- Microphones are normally available unless a reader self-mutes.
- While Rishi TTS is speaking, microphone input is gated.
- Speaking over TTS requires deliberate hold-to-talk and a server-granted speaker floor.
- Only one speaker floor is active at a time.
- TTS ducks while a participant has the speaker floor.
- The reader/controller position, page or scroll state, TTS state, and temporary session annotations are synchronized.
- The controller may transfer control.
- Text chat, reactions, raised hands, recording, and playback are out of scope for the first release.

## Notifications

- In-app notifications are the default for approvals, new book cycles, session assignment, and schedule changes.
- Push notifications are optional and used only when permission exists.
- Email notifications require explicit opt-in.

## Age and safety

- Minors may use Reading Groups.
- The product uses age bands and applies parental consent where legally required.
- Groups and sessions are private by default for minors.
- Adult and minor participants are not placed in the same Reading Session.
- There is no global user search or direct messaging.
- The first release has structured group fields only: name, book, schedule/status, administration, and membership. It has no posts, feeds, comments, or reactions.

## Copyright and hosted-copy boundary

- An admin confirms that they have permission to share a book before creating a group reading share.
- Rishi does not bypass DRM.
- Copyright reports and uploader appeals are submitted on the official Rishi website, not inside the app.
- Rights holders do not need a Rishi account; the website requires a verified email and ownership/authority evidence.
- The Rishi team reviews reports. A report does not automatically disable access.
- A validated claim globally blocks the exact SHA-256 hash across Rishi-hosted copies, revokes Rishi links, and prevents new sessions using that work.
- Modified, reformatted, or near-match files are not automatically removed; they require manual review.
- An already-active session may finish naturally. It receives no new participants after validation. Once it ends, the affected hosted copy and links are removed.
- An uploader may appeal through the same website. The hash block remains during review and may be removed if the appeal succeeds.
- No automatic account warning, strike, or account penalty is issued solely because of a validated claim.
- Reports and ownership evidence are retained only while active, plus a short legally required record period, then securely deleted.
- This section is a product policy draft, not legal advice. Counsel must review the final Terms, copyright process, and age policy for the jurisdictions in which Rishi operates.

## Success criteria

The first release is successful when a user can discover or receive a group invitation, request and receive approval, be automatically assigned to a five-person-or-smaller session, receive the book in their library without a second save step, join the live voice session, follow or temporarily diverge from the controller’s reading position, and receive clear notifications and recovery behavior when membership, scheduling, or connectivity changes.

## Deliberate exclusions

- Global people search, follows, and direct messaging.
- Public session discovery.
- Group posts, feeds, comments, reactions, and persistent discussion forums.
- Multiple current books in one group.
- Parallel sessions for different books in one group.
- Video, recording, replay, and text chat.
- Automatic removal of near-match files.
- Automatic account punishment for copyright claims.
