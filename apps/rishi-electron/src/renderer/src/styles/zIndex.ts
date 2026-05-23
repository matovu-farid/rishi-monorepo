/**
 * Centralized z-index scale for the renderer.
 *
 * Conventional Tailwind utilities (`z-50`, `z-[60]`, etc.) stay in place, but
 * any layer that ships outside the Tailwind ramp should import from here so
 * the stacking contract is documented in a single file.
 *
 * Stacking order (low → high):
 *   - `BACKDROP` / dialog backdrops sit at the bottom of the modal layer.
 *   - `MODAL` content renders above its own backdrop (Radix Dialog uses
 *     `z-50` for both backdrop + content with content painted later).
 *   - `MENU` (popovers, dropdowns, custom Menu) sits inside the modal stack
 *     so a Menu opened *outside* a modal can still float over normal page
 *     chrome — but a Modal opened later (z-[60]+) wins, which is the WCAG-
 *     friendly behavior expected by #202.
 *   - `TOAST` / `TOOLTIP` sit at the top so transient feedback is never
 *     hidden by an open menu.
 *
 * Historical bug: the custom `Menu` portal used `z-[9999]`, which trumped
 * every Modal in the app. After this change, Menu = 50 — equal to a Modal
 * backdrop, but lower than Modal content (which paints later in DOM order
 * within the same stacking context).
 */
export const Z_INDEX = {
  /** Sticky page chrome (nav, app-shell sidebar). */
  STICKY: 10,
  /** Default modal layer — backdrops + content from Radix Dialog/Sheet. */
  MODAL: 50,
  /** Custom popup menus, dropdowns, popovers. Below modals opened later. */
  MENU: 50,
  /** Banners / overlays that must paint above modals (e.g. tutorials). */
  OVERLAY: 60,
  /** Transient feedback (toasts, tooltips). */
  TOAST: 70
} as const

export type ZIndexKey = keyof typeof Z_INDEX
