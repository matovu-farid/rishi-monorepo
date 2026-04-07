/**
 * Tests for sync status listener pattern.
 * Pure JS module -- no mocks needed.
 */

let setSyncStatus: typeof import('../lib/sync/status').setSyncStatus
let onSyncStatusChange: typeof import('../lib/sync/status').onSyncStatusChange
let getSyncStatus: typeof import('../lib/sync/status').getSyncStatus
type SyncStatus = import('../lib/sync/status').SyncStatus

beforeEach(() => {
  // Re-import module fresh for each test to reset module-level state
  jest.resetModules()
  const mod = require('../lib/sync/status')
  setSyncStatus = mod.setSyncStatus
  onSyncStatusChange = mod.onSyncStatusChange
  getSyncStatus = mod.getSyncStatus
})

describe('sync status module', () => {
  it('setSyncStatus(syncing) notifies all registered listeners with (syncing, null)', () => {
    const listener1 = jest.fn()
    const listener2 = jest.fn()

    onSyncStatusChange(listener1)
    onSyncStatusChange(listener2)

    // Clear the immediate calls from registration
    listener1.mockClear()
    listener2.mockClear()

    setSyncStatus('syncing')

    expect(listener1).toHaveBeenCalledWith('syncing', null)
    expect(listener2).toHaveBeenCalledWith('syncing', null)
  })

  it('setSyncStatus(synced) updates lastSyncAt to current time and notifies listeners', () => {
    const listener = jest.fn()
    onSyncStatusChange(listener)
    listener.mockClear()

    const before = Date.now()
    setSyncStatus('synced')
    const after = Date.now()

    expect(listener).toHaveBeenCalledTimes(1)
    const [status, lastSyncAt] = listener.mock.calls[0]
    expect(status).toBe('synced')
    expect(lastSyncAt).toBeGreaterThanOrEqual(before)
    expect(lastSyncAt).toBeLessThanOrEqual(after)
  })

  it('onSyncStatusChange returns unsubscribe function that removes listener', () => {
    const listener = jest.fn()
    const unsubscribe = onSyncStatusChange(listener)
    listener.mockClear()

    unsubscribe()

    setSyncStatus('syncing')
    expect(listener).not.toHaveBeenCalled()
  })

  it('new listener receives current status immediately on registration', () => {
    setSyncStatus('syncing')

    const listener = jest.fn()
    onSyncStatusChange(listener)

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith('syncing', null)
  })

  it('setSyncStatus(error) notifies with (error, previousLastSyncAt)', () => {
    // First set synced to establish a lastSyncAt
    setSyncStatus('synced')
    const { lastSyncAt: prevLastSyncAt } = getSyncStatus()

    const listener = jest.fn()
    onSyncStatusChange(listener)
    listener.mockClear()

    setSyncStatus('error')

    expect(listener).toHaveBeenCalledWith('error', prevLastSyncAt)
  })

  it('setSyncStatus(offline) notifies with (offline, previousLastSyncAt)', () => {
    // First set synced to establish a lastSyncAt
    setSyncStatus('synced')
    const { lastSyncAt: prevLastSyncAt } = getSyncStatus()

    const listener = jest.fn()
    onSyncStatusChange(listener)
    listener.mockClear()

    setSyncStatus('offline')

    expect(listener).toHaveBeenCalledWith('offline', prevLastSyncAt)
  })
})
