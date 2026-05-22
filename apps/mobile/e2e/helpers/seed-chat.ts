/**
 * Host-side helpers for seeding chat fixtures from a Detox test.
 *
 * IMPORTANT — current gap (2026-05-21):
 *   Detox tests run in Node on the host. The fixtures themselves
 *   (`lib/test-fixtures/seed.ts`) execute in the simulator process and
 *   write to the on-device SQLite DB. There is currently no bridge
 *   between the two — the helper below is a thin no-op stub that
 *   throws if a test tries to use it before the bridge lands.
 *
 *   The intended bridge (next agent picks this up) is one of:
 *     1. A deep-link handler in `app/_layout.tsx` that, in
 *        `IS_E2E_TEST` mode, calls `seedChatFixtures` when it
 *        receives `rishimobile://e2e/seed-chat?count=N`. Tests would
 *        then call `device.openURL({ url })` to trigger the seed.
 *     2. A custom launchArg consumed during the app's bootstrap,
 *        e.g. `device.launchApp({ newInstance: true, launchArgs: {
 *        E2E_SEED_CHAT_COUNT: 2 } })`, with the bootstrap reading via
 *        a native module (`react-native-launch-arguments` or similar
 *        — not currently installed).
 *
 * For now, this file exports the ID shape so the assertions in
 * `e2e/chat.test.ts` can target seeded rows by their deterministic
 * ids once the bridge is in place. Tests that rely on `seedChat()`
 * should be marked `.skip` with a clear TODO referencing this file.
 */

/**
 * Deterministic ids used by `lib/test-fixtures/seed.ts`. Tests use
 * these to address a known row without round-tripping through the
 * device DB.
 */
export const seedIds = {
  bookId: (index: number): string => `e2e-seed-book-${index}`,
  conversationId: (index: number): string => `e2e-seed-conv-${index}`,
  userMessageId: (index: number): string => `e2e-seed-msg-user-${index}`,
  assistantMessageId: (index: number): string => `e2e-seed-msg-asst-${index}`,
}

export interface SeedChatOptions {
  count?: number
  includeSourceChunks?: boolean
}

/**
 * Stub host-side seed entry-point. Will throw on call so a
 * misconfigured test fails loudly rather than silently passing with
 * an empty DB.
 *
 * Wire this up once the bridge in `lib/test-fixtures/seed.ts` is
 * reachable from Detox (see top-of-file note for options).
 */
export async function seedChat(_options: SeedChatOptions = {}): Promise<void> {
  throw new Error(
    'seedChat() is not yet wired through to the simulator. ' +
      'See e2e/helpers/seed-chat.ts and lib/test-fixtures/seed.ts.',
  )
}

/**
 * Stub host-side clear entry-point. Mirrors `clearChatFixtures()` in
 * `lib/test-fixtures/seed.ts`. Same wiring gap as `seedChat`.
 */
export async function clearChatSeed(): Promise<void> {
  throw new Error(
    'clearChatSeed() is not yet wired through to the simulator. ' +
      'See e2e/helpers/seed-chat.ts and lib/test-fixtures/seed.ts.',
  )
}
