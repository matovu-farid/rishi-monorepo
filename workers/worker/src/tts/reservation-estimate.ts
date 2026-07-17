/**
 * Conservative narration-duration estimate, in seconds, used to size a TTS
 * usage reservation *before* the provider has generated real audio and the
 * true duration is known (docs/superpowers/specs/2026-07-17-rishi-pricing-trial-launch-prerequisites-design.md,
 * "Narration flow" step 4: "the ledger reserves one trial credit or a
 * conservative paid narration-duration estimate").
 *
 * Formula: `Math.max(1, Math.ceil(text.length / AVG_CHARS_PER_SECOND))`.
 *
 * `AVG_CHARS_PER_SECOND` assumes a typical spoken narration pace of about
 * 150 words per minute and an average English word length of 5 characters
 * plus 1 trailing space/punctuation character (6 characters/word):
 *
 *   150 words/min * 6 chars/word = 900 chars/min = 15 chars/sec
 *
 * This is deliberately biased toward *overestimating* seconds (i.e.
 * reserving slightly more allowance than a fast TTS voice will likely
 * consume), because overestimating only means the ledger holds a larger
 * provisional claim until the commit step settles it — see the "gap"
 * noted in this plan's "Exports for downstream plans" section: today's
 * commit settles at this estimated amount, not a measured duration, so
 * conservative (larger) estimates bias toward undercounting available
 * allowance rather than ever allowing more usage than was actually paid
 * for. `Math.max(1, ...)` guards against a zero-second reservation for
 * a very short (but non-empty, already-validated) input string.
 *
 * `UserUsageLedger.reserveTts(estimateCredits: number)` (see
 * docs/superpowers/plans/2026-07-17-user-usage-ledger-trial-tts.md) accepts
 * this value as its `estimateCredits` parameter. The trial-only
 * implementation available today ignores it entirely (trial TTS always
 * reserves exactly one fixed credit) — this helper exists now so the call
 * site's shape does not need to change again once a later plan makes
 * paid-plan accounting actually consume a seconds-based estimate.
 */
export const AVG_CHARS_PER_SECOND = 15;

export function estimateNarrationSeconds(text: string): number {
  return Math.max(1, Math.ceil(text.length / AVG_CHARS_PER_SECOND));
}
