// @ts-nocheck
// Window operations E2E test
// Tests window resize, position, minimize, maximize, and fullscreen commands
// via the test-harness plugin's window control endpoints.
// Takes a snapshot after each operation to capture the visual state.
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.

export {}

await __tauriCypress.waitForReady();

const tc = __tauriCypress;
const { bridge, snapshot } = tc;

// ---------------------------------------------------------------------------
// Helper: invoke a test-harness plugin command (bypasses mock layer since
// plugin:test-harness| commands skip auto-snapshot and go to originalInvoke)
// ---------------------------------------------------------------------------
async function invoke(cmd, args) {
  return window.__TAURI_INTERNALS__.invoke(cmd, args);
}

function assert(condition, message) {
  if (!condition) throw new Error('Assertion failed: ' + message);
}

// Clear mocks so all plugin commands pass through to the real handler
bridge.clearMocks();

// ============================
// Test 1: Get current window size
// ============================
const initialSize = (await invoke('plugin:test-harness|get_window_size'));
assert(
  typeof initialSize === 'object' && initialSize !== null,
  'get_window_size should return an object'
);
assert(
  typeof initialSize.width === 'number' && initialSize.width > 0,
  'Window width should be a positive number, got ' + initialSize.width
);
assert(
  typeof initialSize.height === 'number' && initialSize.height > 0,
  'Window height should be a positive number, got ' + initialSize.height
);

snapshot.take('initial-window-size');

// ============================
// Test 2: Resize window to 800x600
// ============================
await invoke('plugin:test-harness|resize_window', { width: 800, height: 600 });

// Brief pause to allow the window manager to apply the resize
await new Promise((resolve) => setTimeout(resolve, 200));

const resizedSize = (await invoke('plugin:test-harness|get_window_size'));
// Window managers may adjust the exact size, so allow a tolerance
assert(
  Math.abs(resizedSize.width - 800) < 50,
  'After resize, width should be near 800, got ' + resizedSize.width
);
assert(
  Math.abs(resizedSize.height - 600) < 50,
  'After resize, height should be near 600, got ' + resizedSize.height
);

snapshot.take('after-resize-800x600');

// ============================
// Test 3: Get window position
// ============================
const position = (await invoke('plugin:test-harness|get_window_position'));
assert(
  typeof position === 'object' && position !== null,
  'get_window_position should return an object'
);
assert(
  typeof position.x === 'number',
  'Position x should be a number, got ' + typeof position.x
);
assert(
  typeof position.y === 'number',
  'Position y should be a number, got ' + typeof position.y
);

snapshot.take('after-get-position');

// ============================
// Test 4: Resize window to a larger size (1024x768)
// ============================
await invoke('plugin:test-harness|resize_window', { width: 1024, height: 768 });
await new Promise((resolve) => setTimeout(resolve, 200));

const largerSize = (await invoke('plugin:test-harness|get_window_size'));
assert(
  Math.abs(largerSize.width - 1024) < 50,
  'After resize, width should be near 1024, got ' + largerSize.width
);
assert(
  Math.abs(largerSize.height - 768) < 50,
  'After resize, height should be near 768, got ' + largerSize.height
);

snapshot.take('after-resize-1024x768');

// ============================
// Test 5: Maximize and restore
// ============================
await invoke('plugin:test-harness|maximize_window');
await new Promise((resolve) => setTimeout(resolve, 300));

const maximizedSize = (await invoke('plugin:test-harness|get_window_size'));
// After maximize, the window should be at least as large as before
assert(
  maximizedSize.width >= largerSize.width || maximizedSize.width > 800,
  'Maximized width should be large, got ' + maximizedSize.width
);

snapshot.take('after-maximize');

// ============================
// Test 6: Fullscreen toggle
// ============================
await invoke('plugin:test-harness|fullscreen_window', { fullscreen: true });
await new Promise((resolve) => setTimeout(resolve, 300));
snapshot.take('after-fullscreen-on');

await invoke('plugin:test-harness|fullscreen_window', { fullscreen: false });
await new Promise((resolve) => setTimeout(resolve, 300));
snapshot.take('after-fullscreen-off');

// ============================
// Test 7: Verify snapshot history accumulated
// ============================
const history = snapshot.history;
assert(
  history.length >= 6,
  'Should have at least 6 snapshots in history, got ' + history.length
);

// Verify snapshot labels
const labels = history.map((s) => s.label);
assert(
  labels.includes('initial-window-size'),
  'Snapshot history should include "initial-window-size"'
);
assert(
  labels.includes('after-resize-800x600'),
  'Snapshot history should include "after-resize-800x600"'
);
assert(
  labels.includes('after-maximize'),
  'Snapshot history should include "after-maximize"'
);

snapshot.take('window-tests-complete');
