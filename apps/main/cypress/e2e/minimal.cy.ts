export {};

await __tauriCypress.waitForReady();

// Minimal test - just verifies the script execution works
const msg = "Test script executed successfully";
console.log("[test-harness]", msg);
