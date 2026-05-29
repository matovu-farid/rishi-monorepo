// packages/shared/src/actors/viewActor.ts
//
// The view-actor protocol shared by every per-format implementation
// (epubViewActor, pdfViewActor, mobiViewActor, djvuViewActor) across both
// electron and mobile. Parity with the electron protocol at
// apps/rishi-electron/src/renderer/src/actors/viewActor.ts — see
// .parity/2026-05-28-player-actor-restructure/PLAN.md §3.2.
//
// What every view actor MUST do before emitting VIEW_CHANGED:
//
//   if (newLocator === previousLocator || newParagraphs.length === 0) {
//     sendBack({ type: 'NAV_NO_PROGRESS', reason: '...' })
//   } else {
//     sendBack({ type: 'VIEW_CHANGED', locator: newLocator, paragraphs: newParagraphs })
//   }
//
// This is the validation the prior `publishCurrentEpubParagraphs` safety
// net omitted, which is why republish-after-no-relocation landed playback
// on paragraph 0 of the OLD view.
import type { ParagraphWithIndex } from '../machines/playerMachine'

/** Commands sent FROM playerMachine TO the view actor. */
export type ViewActorCommand =
  /** Advance one view (epub: rendition.next(); pdf: pageControls.nextPage(); etc). */
  | { type: 'NAVIGATE_NEXT' }
  /** Go back one view. */
  | { type: 'NAVIGATE_PREV' }
  /** Jump to a specific locator: CFI string (epub) or page number / anchor (pdf). */
  | { type: 'NAVIGATE_TO'; locator: string }
  /**
   * Re-emit the current view's paragraphs (no navigation). The actor runs the
   * same validation rule as a normal nav:
   *   - if paragraphs are non-empty → VIEW_CHANGED { locator, paragraphs }
   *   - if paragraphs are empty (or locator is unknown) → NAV_NO_PROGRESS
   *     { reason: 'no-relocation' }
   * REPUBLISH intentionally emits VIEW_CHANGED even when the locator is
   * unchanged: it's the "I lost track, tell me again" signal that the player
   * uses to recover from `currentParagraphs = []` after a failed nav.
   */
  | { type: 'REPUBLISH' }

/** Events emitted FROM the view actor BACK to playerMachine via sendBack. */
export type ViewActorEmit =
  /**
   * A new view is committed AND it actually differs from the previous one
   * AND it has paragraphs the player can speak. The two conditions are
   * AND'd so the loop-back race cannot happen by construction.
   */
  | { type: 'VIEW_CHANGED'; locator: string; paragraphs: ParagraphWithIndex[] }
  /**
   * The view actor was asked to navigate but couldn't (end of document,
   * rendition reported no relocation, or the format-specific timeout fired).
   * The player should transition to `stopped` with end-of-document feedback,
   * NOT silently loop back to paragraph 0 of the current view.
   */
  | {
      type: 'NAV_NO_PROGRESS'
      reason: 'end-of-document' | 'no-relocation' | 'timeout'
    }
