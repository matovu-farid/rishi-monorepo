import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, fireEvent } from '@testing-library/react'

const sendMock = vi.fn()
let pillVisible = false
let topAnchor: { label: string } | null = null
let stackDepth = 0

vi.mock('@/hooks/useNavigationHistory', () => ({
  usePillVisible: () => pillVisible,
  useTopAnchor: () => topAnchor,
  useStackDepth: () => stackDepth
}))

vi.mock('@/machines/navigationHistory/navigationHistoryActor', () => ({
  navigationHistoryActor: { send: (e: unknown) => sendMock(e) }
}))

import { NavigationHistoryFooter } from './NavigationHistoryFooter'

describe('NavigationHistoryFooter', () => {
  beforeEach(() => {
    sendMock.mockClear()
    pillVisible = false
    topAnchor = null
    stackDepth = 0
  })

  it('renders nothing when pill is hidden', () => {
    const { container } = render(<NavigationHistoryFooter />)
    expect(container.firstChild).toBeNull()
  })

  it('renders label when visible', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 1
    const { getByRole } = render(<NavigationHistoryFooter />)
    expect(getByRole('status')).toHaveTextContent('p. 142')
  })

  it('appends stack depth when >1', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 3
    const { getByRole } = render(<NavigationHistoryFooter />)
    expect(getByRole('status')).toHaveTextContent('p. 142 (3)')
  })

  it('label click dispatches POP_BACK', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 1
    const { getByTestId } = render(<NavigationHistoryFooter />)
    fireEvent.click(getByTestId('nav-history-back-label'))
    expect(sendMock).toHaveBeenCalledWith({ type: 'POP_BACK' })
  })

  it('dismiss button dispatches DISMISS_PILL', () => {
    pillVisible = true
    topAnchor = { label: 'p. 142' }
    stackDepth = 1
    const { getByTestId } = render(<NavigationHistoryFooter />)
    fireEvent.click(getByTestId('nav-history-dismiss'))
    expect(sendMock).toHaveBeenCalledWith({ type: 'DISMISS_PILL' })
  })

  it('hides when topAnchor is null even if pillVisible is true', () => {
    pillVisible = true
    topAnchor = null
    stackDepth = 0
    const { container } = render(<NavigationHistoryFooter />)
    expect(container.firstChild).toBeNull()
  })
})
