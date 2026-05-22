/**
 * Detox E2E coverage for the **text (RAG) chat** flow.
 *
 * Scope:
 *   - The Chat tab list screen (`app/(tabs)/chat.tsx`)
 *   - The per-book chat detail screen (`app/chat/[bookId].tsx`)
 *   - The chat input + send pipeline (`components/ChatInput.tsx`)
 *
 * Out of scope (other agents):
 *   - Voice chat / realtime ASR (`VoiceMicButton`, `RealtimeVoiceButton`)
 *   - Library / reader / settings flows
 *
 * Detox globals (`device`, `element`, `by`, `expect`, `waitFor`) are
 * injected by the `detox/runners/jest/testEnvironment`. The `expect`
 * used here is Detox's matcher (returns a promise) — do NOT import
 * Jest's expect into this file.
 */
import { seedIds } from './helpers/seed-chat'

// Detox injects its own `expect` as a global (see node_modules/detox/
// globals.d.ts), but `@types/jest` ALSO declares a global `expect`
// with a different shape. The Jest types win the TypeScript merge
// because they're loaded via the `types` array in e2e/tsconfig.json.
// Aliasing the global through a typed local restores the Detox shape
// for the assertions below without touching the shared tsconfig.
const dExpect: Detox.DetoxExportWrapper['expect'] = expect as unknown as Detox.DetoxExportWrapper['expect']

/**
 * Helper: open the Chat tab. Used at the top of every test so each
 * one is self-contained — jest-circus does not guarantee suite-level
 * ordering and the smoke test may have left us on a different tab.
 */
async function openChatTab(): Promise<void> {
  await waitFor(element(by.id('tab-chat')))
    .toBeVisible()
    .withTimeout(60000)
  await element(by.id('tab-chat')).tap()
  await waitFor(element(by.id('screen-chat-list')))
    .toBeVisible()
    .withTimeout(10000)
}

describe('chat: list screen', () => {
  it('renders the empty state with the expected copy when no conversations exist', async () => {
    // PRECONDITION: this assumes the app booted with no seeded
    // conversations (default for the current e2e environment). When
    // the seed bridge is wired (see e2e/helpers/seed-chat.ts), tests
    // that need an empty list should call `clearChatSeed()` first.
    await openChatTab()

    await dExpect(element(by.id('chat-empty-state'))).toBeVisible()
    await dExpect(element(by.id('no-conversations-text'))).toBeVisible()
    await dExpect(element(by.text('No conversations yet'))).toBeVisible()
    await dExpect(
      element(
        by.text('Open a book and tap the AI icon to start a conversation.'),
      ),
    ).toBeVisible()
  })

  it('shows the "+" new-conversation button on the list screen', async () => {
    await openChatTab()

    await dExpect(element(by.id('chat-new-conversation-btn'))).toBeVisible()
  })

  it('opens a "No Books Ready" alert when tapping "+" with an empty library', async () => {
    // With no embedded books, the current implementation surfaces a
    // native Alert prompting the user to open a book first. We
    // assert the alert text rather than navigating, because that is
    // the user-visible contract today.
    //
    // If a future change makes "+" navigate to the library instead,
    // swap this for `await expect(element(by.id('screen-library')))
    // .toBeVisible()` — both shapes satisfy the test plan
    // ("test whichever the current code does").
    await openChatTab()
    await element(by.id('chat-new-conversation-btn')).tap()

    await waitFor(element(by.text('No Books Ready')))
      .toBeVisible()
      .withTimeout(5000)

    // Dismiss the alert so subsequent tests in this worker aren't
    // blocked. Detox/iOS uses the native button label — "OK" is the
    // default. Swallow if the label differs across iOS versions.
    try {
      await element(by.label('OK')).atIndex(0).tap()
    } catch {
      // Cleanup best-effort — the next test's `device.launchApp`
      // will dismiss anything stuck.
    }
  })
})

describe('chat: conversation list with seeded data', () => {
  // TODO(e2e-seed-bridge): every test in this block depends on
  // `lib/test-fixtures/seed.ts` running inside the simulator AND a
  // host-side trigger that fires it (deep-link or launchArg — see
  // e2e/helpers/seed-chat.ts for the design). Until the bridge
  // exists, each test is `.skip`ped with a TODO so the gap is loud.
  //
  // Wiring checklist (next agent):
  //   1. Pick a transport (deep-link is simplest).
  //   2. Add a tiny handler in app/_layout.tsx that, in IS_E2E_TEST
  //      mode only, parses the URL and calls seedChatFixtures().
  //   3. Replace the throwing stubs in e2e/helpers/seed-chat.ts with
  //      `device.openURL({ url: 'rishimobile://e2e/seed-chat?count=N' })`.
  //   4. Remove `.skip` from each test below and add a `beforeAll`
  //      that calls `await seedChat({ count: 2 })`.

  it.skip('renders one row per seeded conversation with book title + last-message snippet', async () => {
    await openChatTab()

    await dExpect(
      element(by.id(`conversation-row-${seedIds.conversationId(0)}`)),
    ).toBeVisible()
    await dExpect(
      element(by.id(`conversation-row-${seedIds.conversationId(1)}`)),
    ).toBeVisible()

    // Book title is rendered as `<rowId>-title` (see ConversationRow).
    await dExpect(
      element(by.id(`conversation-row-${seedIds.conversationId(0)}-title`)),
    ).toBeVisible()
    // Last-message snippet is rendered as `<rowId>-last-message`.
    await dExpect(
      element(
        by.id(`conversation-row-${seedIds.conversationId(0)}-last-message`),
      ),
    ).toBeVisible()
  })

  it.skip('opens the chat detail screen and shows seeded messages on row tap', async () => {
    await openChatTab()
    await element(
      by.id(`conversation-row-${seedIds.conversationId(0)}`),
    ).tap()

    await waitFor(element(by.id('screen-chat-detail')))
      .toBeVisible()
      .withTimeout(10000)

    // The seed inserts exactly one user message + one assistant
    // message per conversation. Both are addressed by their
    // role-indexed testID computed in app/chat/[bookId].tsx.
    await dExpect(element(by.id('chat-message-user-0'))).toBeVisible()
    await dExpect(element(by.id('chat-message-assistant-0'))).toBeVisible()
  })

  it.skip('renders source-reference chips for assistant messages that carry chunks', async () => {
    // Requires seeded data with `includeSourceChunks: true`. The
    // fixture emits `chapter="Page N"` so `formatSourceLabel`
    // renders it as `p. N` (see lib/chat/source-label.ts).
    await openChatTab()
    await element(
      by.id(`conversation-row-${seedIds.conversationId(0)}`),
    ).tap()

    await waitFor(element(by.id('screen-chat-detail')))
      .toBeVisible()
      .withTimeout(10000)

    await dExpect(element(by.id('source-reference-0'))).toBeVisible()
    await dExpect(element(by.text('p. 1'))).toBeVisible()
  })
})

describe('chat: detail screen — input behaviour', () => {
  // These tests cannot reach the chat detail screen without at least
  // one seeded conversation (the "+" button alerts when the library
  // is empty and there is no other entry point from the Chat tab in
  // the current UI). They are kept here, fully written and `.skip`-
  // ped, so they go green automatically the moment the seed bridge
  // lands.
  //
  // We intentionally do NOT assert the assistant response: the chat
  // service calls a Cloudflare worker for completions and we have
  // selected Option B (no assistant stub) for this pass. See the
  // task spec for the rationale.

  it.skip('shows the user message in the list immediately after tapping send', async () => {
    await openChatTab()
    await element(
      by.id(`conversation-row-${seedIds.conversationId(0)}`),
    ).tap()
    await waitFor(element(by.id('screen-chat-detail')))
      .toBeVisible()
      .withTimeout(10000)

    const draft = 'A brand new question from the E2E suite'
    await element(by.id('chat-input')).typeText(draft)
    await element(by.id('chat-send-btn')).tap()

    // The user message is appended at the next role-index (1)
    // because the seed already inserted index 0. We assert ONLY the
    // user bubble — the assistant reply is out of scope.
    await waitFor(element(by.id('chat-message-user-1')))
      .toBeVisible()
      .withTimeout(5000)
    await dExpect(element(by.text(draft))).toBeVisible()

    // TODO(assistant-stub): once a local stub replaces the
    // Cloudflare worker in IS_E2E_TEST mode (Option A), assert
    // `chat-message-assistant-1` becomes visible with the canned
    // reply.
  })

  it.skip('keeps the send button inert when the input is empty', async () => {
    await openChatTab()
    await element(
      by.id(`conversation-row-${seedIds.conversationId(0)}`),
    ).tap()
    await waitFor(element(by.id('screen-chat-detail')))
      .toBeVisible()
      .withTimeout(10000)

    // Make sure the input really is empty (clear any voice-injected
    // text that lingered from a previous test).
    await element(by.id('chat-input')).clearText()

    // Tapping a disabled button is allowed by Detox but should NOT
    // produce a new message bubble.
    await element(by.id('chat-send-btn')).tap()

    // No new user message should have been appended. The seeded
    // conversation has exactly one user message (index 0), so index
    // 1 must remain absent.
    await dExpect(element(by.id('chat-message-user-1'))).not.toExist()
  })
})
