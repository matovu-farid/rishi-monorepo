import { describe, it, expect, vi, beforeEach } from "vitest";
import type { IpcLogEntry } from "../../src/types.js";

let mockLog: IpcLogEntry[] = [];
vi.mock("../../src/bridge.js", () => ({
  bridge: {
    mockCommand: vi.fn(),
    interceptCommand: vi.fn(),
    clearMocks: vi.fn(),
    invoke: vi.fn(),
    getIpcLog: () => mockLog,
    callHelper: vi.fn(),
    getState: vi.fn(),
    takeSnapshot: vi.fn(),
    getSnapshotHistory: vi.fn(),
    removeMock: vi.fn(),
  },
}));

import {
  ipcMockCommand,
  ipcClearMocks,
  ipcGetLog,
} from "../../src/commands/ipc.js";
import { bridge } from "../../src/bridge.js";

describe("IPC commands", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockLog = [];
  });

  it("ipcMockCommand calls bridge.mockCommand", () => {
    ipcMockCommand("get_data", { value: 1 });
    expect(bridge.mockCommand).toHaveBeenCalledWith("get_data", { value: 1 });
  });

  it("ipcClearMocks calls bridge.clearMocks", () => {
    ipcClearMocks();
    expect(bridge.clearMocks).toHaveBeenCalled();
  });

  it("ipcGetLog returns all entries without filter", () => {
    mockLog = [
      { command: "cmd_a", args: null, response: null, mocked: false, duration_ms: 10, timestamp_ms: 1000 },
      { command: "cmd_b", args: null, response: null, mocked: true, duration_ms: 5, timestamp_ms: 2000 },
    ];
    const result = ipcGetLog();
    expect(result).toHaveLength(2);
  });

  it("ipcGetLog filters by command name", () => {
    mockLog = [
      { command: "cmd_a", args: null, response: null, mocked: false, duration_ms: 10, timestamp_ms: 1000 },
      { command: "cmd_b", args: null, response: null, mocked: true, duration_ms: 5, timestamp_ms: 2000 },
    ];
    const result = ipcGetLog("cmd_a");
    expect(result).toHaveLength(1);
    expect(result[0].command).toBe("cmd_a");
  });
});
