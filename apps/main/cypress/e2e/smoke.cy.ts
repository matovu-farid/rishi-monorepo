// Smoke test: verify app loads
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.
export {}

// Wait for invoke patching to complete
await __tauriCypress.waitForReady();
const { bridge, snapshot } = __tauriCypress;

// Wait for DOM to be ready
await new Promise(r => setTimeout(r, 1000));

// Verify root element exists
const root = document.getElementById('root');
if (!root) throw new Error('Root element not found');
if (root.offsetHeight === 0) throw new Error('Root element not visible');

// Take a snapshot of the loaded app
snapshot.take('app-loaded');
