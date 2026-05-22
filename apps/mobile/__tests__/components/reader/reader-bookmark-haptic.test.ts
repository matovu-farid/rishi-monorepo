/**
 * RDR-027 — Bookmark toggle gives no haptic confirmation of "add" vs
 * "remove" — pre-fix the EPUB/PDF/MOBI/DJVU readers only call
 * `AccessibilityInfo.announceForAccessibility`, which is silent for
 * sighted users.
 *
 * Post-fix: each reader's bookmark toggle dispatches a notification haptic
 * differentiated by outcome:
 *   - `Haptics.notificationAsync(Success)` on create
 *   - `Haptics.notificationAsync(Warning)` on remove
 *
 * Source-grep is the established pattern in this suite — we avoid
 * mounting the full reader screens because they pull in WebView,
 * expo-file-system, and many other native modules that have nothing to do
 * with this fix.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

function readReader(relPath: string): string {
  return readFileSync(join(MOBILE_ROOT, relPath), 'utf-8')
}

const READERS = [
  { name: 'EPUB', path: 'app/reader/[id].tsx' },
  { name: 'PDF', path: 'app/reader/pdf/[id].tsx' },
  { name: 'MOBI', path: 'app/reader/mobi/[id].tsx' },
  { name: 'DJVU', path: 'app/reader/djvu/[id].tsx' },
] as const

describe.each(READERS)(
  'RDR-027 — $name reader bookmark toggle fires differentiated haptics',
  ({ path }) => {
    const src = readReader(path)

    it('imports expo-haptics', () => {
      expect(src).toMatch(/from\s+['"]expo-haptics['"]/)
    })

    it("fires Haptics.notificationAsync with Success on create", () => {
      // Success notification — distinct from the warning case below.
      expect(src).toMatch(/NotificationFeedbackType\.Success/)
    })

    it("fires Haptics.notificationAsync with Warning on remove", () => {
      expect(src).toMatch(/NotificationFeedbackType\.Warning/)
    })

    it('branches the haptic on the toggleBookmark result.action', () => {
      // The branch lives inside handleToggleBookmark — both literals
      // appear in the same source. We pin the branch shape so a future
      // refactor that loses the distinction fails the test.
      expect(src).toMatch(
        /result\.action\s*===\s*['"]created['"][\s\S]{0,400}Success/,
      )
    })
  },
)
