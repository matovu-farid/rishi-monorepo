/**
 * Extract a human-readable message from an unknown thrown value.
 * Mirrors `err.message` for `Error` instances and falls back to `String(err)`
 * for anything else (strings, numbers, plain objects, etc.).
 */
export function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
