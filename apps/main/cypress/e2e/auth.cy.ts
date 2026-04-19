// Authentication test with IPC mocking
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.
export {}

const { bridge, ipc } = __tauriCypress;

// ---------------------------------------------------------------------------
// Helper: invoke a Tauri command through the monkey-patched invoke pathway
// ---------------------------------------------------------------------------
async function invoke(cmd: string, args?: unknown): Promise<unknown> {
  return window.__TAURI_INTERNALS__.invoke(cmd, args);
}

// Mock unauthenticated state
bridge.mockCommand('check_auth_status', { authenticated: false, user: null });

const status1 = await invoke('check_auth_status', {}) as { authenticated: boolean; user: null };
if (status1.authenticated !== false) throw new Error('Should be unauthenticated');

// Now mock authenticated state
bridge.mockCommand('check_auth_status', {
  authenticated: true,
  user: { id: 'user-1', email: 'test@example.com', name: 'Test User' }
});

const status2 = await invoke('check_auth_status', {}) as { authenticated: boolean; user: { id: string; email: string; name: string } };
if (status2.authenticated !== true) throw new Error('Should be authenticated');
if (status2.user.email !== 'test@example.com') throw new Error('User email mismatch');

// Verify IPC log
const authCalls = ipc.log.filter(e => e.command === 'check_auth_status');
if (authCalls.length !== 2) throw new Error(`Expected 2 auth calls, got ${authCalls.length}`);
if (!authCalls[0].mocked || !authCalls[1].mocked) throw new Error('Both calls should be mocked');

bridge.clearMocks();
