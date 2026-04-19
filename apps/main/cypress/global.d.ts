import type { TauriCypressGlobal } from 'tauri-cypress';

declare global {
  /** Injected by the Rust test-harness plugin before each script runs. */
  const __tauriCypress: TauriCypressGlobal;
}
