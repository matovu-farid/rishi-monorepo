import { bridge } from "../bridge.js";
import type { IpcLogEntry } from "../types.js";

export function ipcMockCommand(name: string, response: unknown): void {
  bridge.mockCommand(name, response);
}

export function ipcInterceptCommand(
  name: string,
  handler: (args: unknown) => unknown
): void {
  bridge.interceptCommand(name, handler);
}

export function ipcClearMocks(): void {
  bridge.clearMocks();
}

export async function ipcInvoke(
  command: string,
  args?: unknown
): Promise<unknown> {
  return bridge.invoke(command, args);
}

export function ipcGetLog(filter?: string): IpcLogEntry[] {
  const log = bridge.getIpcLog();
  if (!filter) return log;
  return log.filter((entry) => entry.command === filter);
}
