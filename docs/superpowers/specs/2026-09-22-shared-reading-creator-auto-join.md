# Shared reading creator auto-join

## Goal

Starting group reading behaves like starting a Zoom meeting: the creator enters
the room immediately, then shares the invite with other readers.

## Current failure

Creating a room leaves it unoccupied until the creator explicitly taps **Open
group session**. The sharing Durable Object expires an unoccupied room after
two minutes. A recipient who opens the invite after that receives
`SESSION_ENDED`.

## Design

1. A successful `create` response already contains the creator's verified
   invite token.
2. The Apple client must enqueue that token automatically after creation,
   without requiring a second creator-only action.
3. The existing pending-redeem flow redeems the token, verifies the creator's
   local book, obtains an admission ticket, opens the signaling connection,
   and presents the session. This establishes the creator as the first
   connected participant before they invite others.
4. The share composer closes before the session sheet opens, preserving the
   existing single-sheet presentation invariant.
5. A failed automatic join remains visible as the existing typed error alert;
   it must not silently leave a newly created room unoccupied.

## Non-goals

- Changing the room expiry policy.
- Altering invite-token security or session-controller rules.
- Adding automated tests, per the user's implementation-only request.

## Verification

- Build and launch the latest app on the iPhone 17 Pro Simulator.
- Deploy the Worker only if backend changes are necessary (they are not
  expected for this client-flow correction).
