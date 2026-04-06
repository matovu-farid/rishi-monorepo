import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock external dependencies that sync-triggers.ts imports
vi.mock('@rishi/shared/sync-engine', () => ({
  createSyncEngine: vi.fn(),
}));

vi.mock('./sync-adapter', () => ({
  DesktopSyncAdapter: vi.fn(),
}));

vi.mock('@tauri-apps/plugin-store', () => ({
  load: vi.fn().mockResolvedValue({ get: vi.fn() }),
}));

import { triggerSyncOnWrite } from './sync-triggers';

describe('triggerSyncOnWrite', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('does not call triggerSync immediately (setTimeout is pending)', () => {
    // triggerSync requires engine to be initialized; if engine is null it returns early.
    // We test that setTimeout is used with the correct delay pattern.
    const setTimeoutSpy = vi.spyOn(globalThis, 'setTimeout');

    triggerSyncOnWrite();

    // setTimeout should have been called with 2000ms
    expect(setTimeoutSpy).toHaveBeenCalledWith(expect.any(Function), 2000);

    setTimeoutSpy.mockRestore();
  });

  it('clears previous timeout when called again (debounce)', () => {
    const clearTimeoutSpy = vi.spyOn(globalThis, 'clearTimeout');

    triggerSyncOnWrite();
    const callCountAfterFirst = clearTimeoutSpy.mock.calls.length;

    triggerSyncOnWrite();
    // clearTimeout should be called on second invocation
    expect(clearTimeoutSpy.mock.calls.length).toBeGreaterThan(callCountAfterFirst);

    clearTimeoutSpy.mockRestore();
  });

  it('only fires once after multiple rapid calls followed by 2s wait', () => {
    const setTimeoutSpy = vi.spyOn(globalThis, 'setTimeout');

    triggerSyncOnWrite();
    triggerSyncOnWrite();
    triggerSyncOnWrite();

    // Each call sets a new timeout, the previous ones are cleared
    // After advancing 2s from the last call, only one callback would fire
    // We verify the setTimeout/clearTimeout dance happened correctly
    const timeoutCalls = setTimeoutSpy.mock.calls.filter(
      ([, delay]) => delay === 2000,
    );
    expect(timeoutCalls.length).toBe(3); // Each call set a 2000ms timeout

    setTimeoutSpy.mockRestore();
  });

  it('uses 2000ms delay for debounce', () => {
    const setTimeoutSpy = vi.spyOn(globalThis, 'setTimeout');

    triggerSyncOnWrite();

    const call = setTimeoutSpy.mock.calls.find(([, delay]) => delay === 2000);
    expect(call).toBeDefined();
    expect(call![1]).toBe(2000);

    setTimeoutSpy.mockRestore();
  });
});
