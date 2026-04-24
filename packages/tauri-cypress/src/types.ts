/** Result of a single assertion */
export interface AssertionResult {
  description: string;
  passed: boolean;
  expected: unknown;
  actual: unknown;
}

/** IPC log entry from the Rust plugin */
export interface IpcLogEntry {
  command: string;
  args: unknown;
  response: unknown;
  mocked: boolean;
  duration_ms: number;
  timestamp_ms: number;
}

/** DOM snapshot captured by the Rust plugin */
export interface DomSnapshot {
  label: string;
  html: string;
  url: string;
  timestamp_ms: number;
}

/** Global configuration for cy commands */
export interface CyConfig {
  defaultCommandTimeout: number;
  execTimeout: number;
}

/** A matcher function that checks a subject against expected values */
export type MatcherFn = (
  subject: unknown,
  ...args: unknown[]
) => { passed: boolean; actual: unknown; expected: unknown };

/**
 * Represents a queued command in the chain.
 * - "query" commands are retryable (get, find, first, etc.)
 * - "action" commands execute once (click, type, visit, etc.)
 * - "assertion" commands trigger retry of preceding query (should, and)
 */
export type CommandType = "query" | "action" | "assertion";

export interface QueuedCommand {
  type: CommandType;
  name: string;
  fn: (subject: unknown) => unknown | Promise<unknown>;
  timeout?: number;
}

/** The __tauriCypress global injected by the Rust plugin */
export interface TauriCypressGlobal {
  bridge: {
    invoke: (cmd: string, args?: unknown, options?: unknown) => Promise<unknown>;
    mockCommand: (name: string, response: unknown) => void;
    interceptCommand: (
      name: string,
      handler: (args: unknown) => unknown
    ) => void;
    removeMock: (name: string) => void;
    clearMocks: () => void;
    getState: (key: string) => Promise<unknown>;
    callHelper: (name: string, args: unknown) => Promise<unknown>;
  };
  ipc: {
    intercept: (
      name: string,
      handler: (args: unknown) => unknown
    ) => void;
    passthrough: (name: string) => void;
    readonly log: IpcLogEntry[];
  };
  snapshot: {
    take: (label: string) => DomSnapshot;
    readonly history: DomSnapshot[];
  };
  __exec: (script: string, testId: string) => Promise<void>;
}

declare global {
  interface Window {
    __tauriCypress: TauriCypressGlobal;
    __TAURI_INTERNALS__: {
      invoke: (cmd: string, args?: unknown, options?: unknown) => Promise<unknown>;
    };
  }
}
