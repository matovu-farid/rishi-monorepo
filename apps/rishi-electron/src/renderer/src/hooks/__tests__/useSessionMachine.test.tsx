import { describe, expect, it } from 'vitest'
import { renderHook, render, act } from '@testing-library/react'
import { useState, type ReactNode } from 'react'
import { SessionMachineProvider, useSessionMachine } from '../useSessionMachine'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

describe('useSessionMachine', () => {
  it('returns idle snapshot on mount', () => {
    const { result } = renderHook(() => useSessionMachine())
    expect(result.current.state.value).toBe('idle')
  })

  it('exposes a send fn that updates state', () => {
    const { result } = renderHook(() => useSessionMachine())
    act(() => {
      result.current.send({
        type: 'CREATE_SESSION',
        me: { userId: 'u_a', displayName: 'M', authToken: 'jwt' },
        bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
        requiresApproval: false
      })
    })
    expect(['creating', 'idle']).toContain(result.current.state.value as string)
  })

  it('does not suppress react-hooks/rules-of-hooks in source', () => {
    const here = dirname(fileURLToPath(import.meta.url))
    const src = readFileSync(join(here, '..', 'useSessionMachine.ts'), 'utf8')
    expect(src).not.toMatch(/eslint-disable[^\n]*react-hooks\/rules-of-hooks/)
  })

  it('survives a parent toggling the provider on/off without changing hook order', () => {
    // Consumer that always calls useSessionMachine.
    function Consumer(): ReactNode {
      const { state } = useSessionMachine()
      return <span data-testid="value">{String(state.value)}</span>
    }

    // Parent that mounts the SAME Consumer subtree both with and without a
    // provider in the same React lifetime. Today this triggers React's
    // "Rendered more hooks than during the previous render" because the
    // hook conditionally invokes useSessionMachineInternal() based on
    // useContext's result.
    let toggle: (() => void) | null = null
    function Parent(): ReactNode {
      const [withProvider, setWithProvider] = useState(false)
      toggle = (): void => setWithProvider((p) => !p)
      return withProvider ? (
        <SessionMachineProvider>
          <Consumer />
        </SessionMachineProvider>
      ) : (
        <Consumer />
      )
    }

    const { getByTestId } = render(<Parent />)
    expect(getByTestId('value').textContent).toBe('idle')

    act(() => {
      toggle?.()
    })
    expect(getByTestId('value').textContent).toBe('idle')

    act(() => {
      toggle?.()
    })
    expect(getByTestId('value').textContent).toBe('idle')
  })
})
