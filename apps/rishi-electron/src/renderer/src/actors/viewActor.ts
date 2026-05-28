// apps/electron/src/renderer/src/actors/viewActor.ts
//
// The view-actor protocol shared by every per-format implementation
// (epubViewActor, pdfViewActor, mobiViewActor, djvuViewActor).
//
// The protocol exists because the view-boundary bug class — "paragraph 0 of
// the new view never plays after auto-advance" — is NOT specific to EPUB.
// PDF has it (regression: e2e/pdf-next-paragraph-snap-back.spec.ts), MOBI
// and DJVU have latent risk. One protocol, one validation rule, one fix.
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
import type { ParagraphWithIndex } from '@/stores/playerStore'

/** Commands sent FROM playerMachine TO the view actor. */
export type ViewActorCommand =
  /** Advance one view (epub: rendition.next(); pdf: pageControls.nextPage(); etc). */
  | { type: 'NAVIGATE_NEXT' }
  /** Go back one view. */
  | { type: 'NAVIGATE_PREV' }
  /** Jump to a specific locator: CFI string (epub) or page number / anchor (pdf). */
  | { type: 'NAVIGATE_TO'; locator: string }

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
