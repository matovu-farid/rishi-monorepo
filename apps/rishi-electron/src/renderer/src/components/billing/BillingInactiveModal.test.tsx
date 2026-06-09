import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react'
import { BillingInactiveModal } from './BillingInactiveModal'
import { useBillingStore } from '@/stores/billingStore'

const workerFetchMock = vi.fn()
vi.mock('@/lib/api', () => ({
  workerFetch: (path: string, init?: RequestInit) => workerFetchMock(path, init)
}))

function jsonResponse(status: number, body: unknown = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}

beforeEach(() => {
  workerFetchMock.mockReset()
  ;(window.electron.openExternal as ReturnType<typeof vi.fn>).mockClear()
  useBillingStore.setState({ billingInactive: false, subscriptionStatus: null })
})

describe('BillingInactiveModal', () => {
  it('is not in the DOM when billingInactive is false', () => {
    render(<BillingInactiveModal />)
    expect(screen.queryByTestId('billing-inactive-modal')).toBeNull()
  })

  it('renders past_due copy when status is past_due', () => {
    useBillingStore.setState({ billingInactive: true, subscriptionStatus: 'past_due' })
    render(<BillingInactiveModal />)
    expect(screen.getByTestId('billing-inactive-title')).toHaveTextContent(/payment failed/i)
    expect(screen.getByTestId('billing-inactive-manage')).toHaveTextContent(
      /update payment method/i
    )
  })

  it('renders unknown copy when status is null', () => {
    useBillingStore.setState({ billingInactive: true, subscriptionStatus: null })
    render(<BillingInactiveModal />)
    expect(screen.getByTestId('billing-inactive-title')).toHaveTextContent(/subscription required/i)
    expect(screen.getByTestId('billing-inactive-manage')).toHaveTextContent(/manage subscription/i)
  })

  it('Manage CTA POSTs /api/billing/start, opens URL, then dismisses store', async () => {
    workerFetchMock.mockResolvedValueOnce(
      jsonResponse(200, { url: 'https://billing.stripe.com/start' })
    )
    useBillingStore.setState({ billingInactive: true, subscriptionStatus: 'canceled' })

    render(<BillingInactiveModal />)
    await act(async () => {
      fireEvent.click(screen.getByTestId('billing-inactive-manage'))
    })

    await waitFor(() => expect(workerFetchMock).toHaveBeenCalledTimes(1))
    const [path, init] = workerFetchMock.mock.calls[0]!
    expect(path).toBe('/api/billing/start')
    expect(init.method).toBe('POST')

    await waitFor(() => {
      expect(window.electron.openExternal).toHaveBeenCalledWith('https://billing.stripe.com/start')
    })
    await waitFor(() => {
      expect(useBillingStore.getState().billingInactive).toBe(false)
    })
  })

  it('Manage CTA failure shows error and does not dismiss', async () => {
    workerFetchMock.mockResolvedValueOnce(jsonResponse(500))
    useBillingStore.setState({ billingInactive: true, subscriptionStatus: 'past_due' })

    render(<BillingInactiveModal />)
    await act(async () => {
      fireEvent.click(screen.getByTestId('billing-inactive-manage'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('billing-inactive-error')).toHaveTextContent(/Couldn't reach/i)
    })
    expect(window.electron.openExternal).not.toHaveBeenCalled()
    expect(useBillingStore.getState().billingInactive).toBe(true)
  })

  it('Manage CTA 503 shows not-available error', async () => {
    workerFetchMock.mockResolvedValueOnce(jsonResponse(503))
    useBillingStore.setState({ billingInactive: true, subscriptionStatus: 'past_due' })

    render(<BillingInactiveModal />)
    await act(async () => {
      fireEvent.click(screen.getByTestId('billing-inactive-manage'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('billing-inactive-error')).toHaveTextContent(/isn't available/i)
    })
    expect(window.electron.openExternal).not.toHaveBeenCalled()
  })

  it('Dismiss CTA clears the store', async () => {
    useBillingStore.setState({ billingInactive: true, subscriptionStatus: 'canceled' })
    render(<BillingInactiveModal />)

    await act(async () => {
      fireEvent.click(screen.getByTestId('billing-inactive-dismiss'))
    })

    await waitFor(() => {
      const s = useBillingStore.getState()
      expect(s.billingInactive).toBe(false)
      expect(s.subscriptionStatus).toBeNull()
    })
  })
})
