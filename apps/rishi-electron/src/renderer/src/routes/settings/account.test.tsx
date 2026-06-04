import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react'
import { AccountSettings } from './account'
import { useAuthStore } from '@/stores/authStore'

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

function seedUser(): void {
  useAuthStore.setState({
    user: { id: 'u1', email: 'a@b.com' } as unknown as ReturnType<
      typeof useAuthStore.getState
    >['user']
  })
}

beforeEach(() => {
  workerFetchMock.mockReset()
  ;(window.electron.openExternal as ReturnType<typeof vi.fn>).mockClear()
  seedUser()
})

describe('AccountSettings — Manage billing button', () => {
  it('renders a Manage billing button', () => {
    render(<AccountSettings />)
    expect(
      screen.getByRole('button', { name: /manage billing/i })
    ).toBeInTheDocument()
  })

  it('clicking the button POSTs to /api/billing/portal and opens the URL', async () => {
    workerFetchMock.mockResolvedValueOnce(
      jsonResponse(200, { url: 'https://billing.stripe.com/xyz' })
    )

    render(<AccountSettings />)
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /manage billing/i }))
    })

    await waitFor(() => expect(workerFetchMock).toHaveBeenCalledTimes(1))
    const [path, init] = workerFetchMock.mock.calls[0]!
    expect(path).toBe('/api/billing/portal')
    expect(init.method).toBe('POST')
    expect(init.body).toBe(JSON.stringify({}))

    await waitFor(() => {
      expect(window.electron.openExternal).toHaveBeenCalledWith(
        'https://billing.stripe.com/xyz'
      )
    })
  })

  it('shows a "not available" message on 503', async () => {
    workerFetchMock.mockResolvedValueOnce(jsonResponse(503))

    render(<AccountSettings />)
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /manage billing/i }))
    })

    await waitFor(() => {
      expect(screen.getByText(/not available/i)).toBeInTheDocument()
    })
    expect(window.electron.openExternal).not.toHaveBeenCalled()
  })

  it('shows a "contact support" message on 409', async () => {
    workerFetchMock.mockResolvedValueOnce(jsonResponse(409))

    render(<AccountSettings />)
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /manage billing/i }))
    })

    await waitFor(() => {
      expect(screen.getByText(/contact support/i)).toBeInTheDocument()
    })
    expect(window.electron.openExternal).not.toHaveBeenCalled()
  })

  it('shows a network-error message when workerFetch throws', async () => {
    workerFetchMock.mockRejectedValueOnce(new Error('network down'))

    render(<AccountSettings />)
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: /manage billing/i }))
    })

    await waitFor(() => {
      expect(screen.getByText(/Couldn't reach/i)).toBeInTheDocument()
    })
    expect(window.electron.openExternal).not.toHaveBeenCalled()
  })
})
