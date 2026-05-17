/**
 * Regression tests for the popover delete-race.
 *
 * Scenario: SelectionPopover renders edit/delete tied to the parent's
 * highlight context. A *sibling* popover (HighlightActionPopover) registers
 * an outside-click listener on the document that fires on every mousedown
 * outside its container. When the user clicks delete inside SelectionPopover,
 * that listener fires during the mousedown phase — BEFORE the click resolves.
 *
 * Browser event order for a button click:
 *   mousedown → mouseup → click
 *
 * If the parent state that gates `onDelete` is cleared in the mousedown
 * phase, React re-renders and unmounts the button before the click can fire.
 * The delete silently does nothing — the original "delete is not working"
 * bug.
 *
 * The fix is to gate the SelectionPopover's edit/delete on a STABLE state
 * (one whose lifetime matches the SelectionPopover, not the sibling
 * popover). The two tests below pin both ends of the contract.
 */
import { describe, it, expect, vi } from 'vitest'
import { useEffect, useState } from 'react'
import { render, screen, fireEvent } from '@testing-library/react'
import { SelectionPopover } from './SelectionPopover'

describe('Popover delete-race', () => {
  it('BUG pattern (fails): gating onDelete on transient state cleared by sibling mousedown unmounts the button before click fires', () => {
    const onDeleteSpy = vi.fn()

    function BuggyHarness() {
      const [transient, setTransient] = useState<{ cfi: string } | null>({ cfi: 'cfi:transient' })
      useEffect(() => {
        const handler = (): void => setTransient(null)
        document.addEventListener('mousedown', handler)
        return () => document.removeEventListener('mousedown', handler)
      }, [])
      return (
        <SelectionPopover
          cfiRange="cfi:selection"
          selectedText="x"
          position={{ x: 0, y: 0 }}
          onHighlight={vi.fn()}
          onClose={vi.fn()}
          // BUG: depends on transient state cleared by sibling listener.
          onDelete={transient ? () => onDeleteSpy(transient.cfi) : undefined}
        />
      )
    }

    render(<BuggyHarness />)
    const button = screen.getByRole('button', { name: /delete highlight/i })
    fireEvent.mouseDown(button) // sibling listener clears `transient`, React unmounts the button
    fireEvent.click(button)
    // Documenting the failure mode: spy is NOT called because button unmounts.
    expect(onDeleteSpy).not.toHaveBeenCalled()
  })

  it('FIX pattern: gating onDelete on a STABLE state (independent of sibling popover) lets delete fire correctly', () => {
    const onDeleteSpy = vi.fn()

    function FixedHarness() {
      // Mirrors the EpubView fix: a transient "inline popover open" flag
      // that the sibling listener clears, AND a stable "highlight context"
      // that SelectionPopover uses for edit/delete. The two are decoupled.
      const [transientPopoverOpen, setTransientPopoverOpen] = useState(true)
      const [stableContext] = useState<{ cfi: string } | null>({ cfi: 'cfi:stable' })

      useEffect(() => {
        const handler = (): void => setTransientPopoverOpen(false)
        document.addEventListener('mousedown', handler)
        return () => document.removeEventListener('mousedown', handler)
      }, [])

      return (
        <>
          {transientPopoverOpen ? <div data-testid="sibling-popover" /> : null}
          <SelectionPopover
            cfiRange="cfi:selection"
            selectedText="x"
            position={{ x: 0, y: 0 }}
            onHighlight={vi.fn()}
            onClose={vi.fn()}
            // FIX: depends on stable state that survives the mousedown race.
            onDelete={stableContext ? () => onDeleteSpy(stableContext.cfi) : undefined}
          />
        </>
      )
    }

    render(<FixedHarness />)
    // Sibling is initially mounted.
    expect(screen.getByTestId('sibling-popover')).toBeInTheDocument()

    const button = screen.getByRole('button', { name: /delete highlight/i })
    fireEvent.mouseDown(button) // sibling listener clears its open flag
    fireEvent.click(button)

    // Sibling unmounted (transient state cleared by mousedown listener), but
    // the delete still fires because it was tied to stable context.
    expect(screen.queryByTestId('sibling-popover')).toBeNull()
    expect(onDeleteSpy).toHaveBeenCalledTimes(1)
    expect(onDeleteSpy).toHaveBeenCalledWith('cfi:stable')
  })
})
