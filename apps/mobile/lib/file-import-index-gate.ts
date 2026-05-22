/**
 * Pure predicate extracted from file-import.ts so the gating logic is
 * unit-testable without dragging in expo-file-system or the import
 * service. Both call sites in file-import.ts use this.
 *
 * Gating rules:
 *   - E2E mode always skips (no real backend session).
 *   - Production with no session token skips (avoids noisy Worker
 *     401s; indexing will retry next time the book opens after the
 *     user signs in, gated by vector-store.isBookEmbedded).
 *   - Production with a session token proceeds.
 */
export interface IndexGateInput {
  isE2E: boolean
  sessionToken: string | null
}

export function shouldSkipIndexing(input: IndexGateInput): boolean {
  if (input.isE2E) return true
  if (!input.sessionToken) return true
  return false
}
