/**
 * RDR-025 — Reader-shell auto-hide ignores user touch events.
 *
 * Pre-fix: the 3s auto-hide timer is only re-armed when `toolbarVisible`
 * flips. A user who reads the chapter label / progress pill area can't
 * keep chrome visible — the bar disappears under their finger.
 *
 * Post-fix: `ReaderShellContext` exposes an `interact()` method that the
 * bottom bar wires to `onTouchStart`. Calling it bumps a touch-tick
 * counter that's a dep of the auto-hide effect, so the 3s timer restarts
 * each time the user touches the bar without flipping visibility.
 *
 * Source-grep follows the established pattern in this suite — we avoid
 * mounting the full reader because it pulls in many heavy native modules.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

function read(rel: string): string {
  return readFileSync(join(MOBILE_ROOT, rel), 'utf-8')
}

describe('RDR-025 — ReaderShell exposes an `interact` reset that re-arms the timer', () => {
  const shell = read('components/reader/ReaderShell.tsx')
  // RDR-025 — context type was lifted into its own module so leaf
  // consumers (ReaderBottomBar) can import the context without pulling
  // in the rest of the reader stack. Check both files for the type.
  const ctx = read('components/reader/ReaderShellContext.tsx')

  it("ReaderShellContext.interact exists in the context type", () => {
    expect(ctx).toMatch(/interact:\s*\(\)\s*=>\s*(void|undefined)/)
  })

  it('the auto-hide effect depends on a touch-tick counter so calling interact resets the timer', () => {
    // The effect's deps array should contain the touch-tick identifier so
    // each `interact()` call schedules a fresh 3s timeout.
    expect(shell).toMatch(/touchTick|interactTick|lastInteractAt/)
  })

  it('interact bumps the tick / state without flipping toolbarVisible', () => {
    // The interact callback should NOT call setToolbarVisible — it merely
    // re-arms the timer.
    const match = shell.match(/const\s+interact[\s\S]*?\}\s*,\s*\[/)
    if (!match) {
      throw new Error(
        'interact callback not found in ReaderShell.tsx (or its shape changed)',
      )
    }
    expect(match[0]).not.toMatch(/setToolbarVisible/)
  })
})

describe('RDR-025 — ReaderBottomBar wires onTouchStart to interact', () => {
  const bar = read('components/reader/ReaderBottomBar.tsx')

  it('imports / consumes ReaderShellContext', () => {
    expect(bar).toMatch(/ReaderShellContext/)
  })

  it('the bar mounts an onTouchStart handler that calls interact', () => {
    // The handler may be wired on the outer wrapper View; we just check
    // that the wiring exists somewhere in the file.
    expect(bar).toMatch(/onTouchStart/)
    expect(bar).toMatch(/interact\s*\(\s*\)/)
  })
})
