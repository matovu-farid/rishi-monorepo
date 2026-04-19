import type { IpcLogEntry, DomSnapshot } from "./types.js";

function getTauriCypress() {
  if (typeof window === "undefined" || !window.__tauriCypress) {
    throw new Error(
      "tauri-cypress: __tauriCypress not found. " +
        "Is tauri-plugin-test-harness loaded?"
    );
  }
  return window.__tauriCypress;
}

export const bridge = {
  mockCommand(name: string, response: unknown): void {
    getTauriCypress().bridge.mockCommand(name, response);
  },

  interceptCommand(
    name: string,
    handler: (args: unknown) => unknown
  ): void {
    getTauriCypress().bridge.interceptCommand(name, handler);
  },

  removeMock(name: string): void {
    getTauriCypress().bridge.removeMock(name);
  },

  clearMocks(): void {
    getTauriCypress().bridge.clearMocks();
  },

  getState(key: string): Promise<unknown> {
    return getTauriCypress().bridge.getState(key);
  },

  callHelper(name: string, args?: unknown): Promise<unknown> {
    return getTauriCypress().bridge.callHelper(name, args ?? null);
  },

  getIpcLog(): IpcLogEntry[] {
    return getTauriCypress().ipc.log;
  },

  takeSnapshot(label: string): DomSnapshot {
    return getTauriCypress().snapshot.take(label);
  },

  getSnapshotHistory(): DomSnapshot[] {
    return getTauriCypress().snapshot.history;
  },

  invoke(cmd: string, args?: unknown): Promise<unknown> {
    return window.__TAURI_INTERNALS__.invoke(cmd, args);
  },
};
