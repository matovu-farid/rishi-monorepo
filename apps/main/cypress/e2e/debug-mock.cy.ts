export {}

const { bridge } = __tauriCypress;

// Set up mock
bridge.mockCommand('check_auth_status', { authenticated: false });

// Try invoke through the bridge (mock-aware)
var result = await bridge.invoke('check_auth_status', {});
if (!result || result.authenticated !== false) {
  throw new Error('Mock did not intercept. Got: ' + JSON.stringify(result).substring(0, 200));
}
