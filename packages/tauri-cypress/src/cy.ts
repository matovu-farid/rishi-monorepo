import { domGet, domContains, domFind, domFirst, domLast, domEq, domClick, domType, domClear, domCheck, domSelect } from "./commands/dom.js";
import { navVisit, navReload, navUrl, navHash, navGo } from "./commands/navigation.js";
import { ipcMockCommand, ipcInterceptCommand, ipcClearMocks, ipcInvoke, ipcGetLog } from "./commands/ipc.js";
import { rustHelper as rustHelperCmd, rustAppState } from "./commands/rust.js";
import { winResize, winMinimize, winMaximize, winFullscreen, winPosition, winSize } from "./commands/window.js";
import { snapshotTake, snapshotScreenshot } from "./commands/snapshot.js";
import { applyMatcher } from "./assertions/matchers.js";
import type { IpcLogEntry, DomSnapshot } from "./types.js";
import type { QueuedCommand, AssertionResult, CyConfig } from "./types.js";
import { retry } from "./retry.js";

const DEFAULT_CONFIG: CyConfig = {
  defaultCommandTimeout: 4000,
  execTimeout: 60000,
};

let globalConfig: CyConfig = { ...DEFAULT_CONFIG };

export function getConfig(): CyConfig {
  return globalConfig;
}

export function setConfig(overrides: Partial<CyConfig>): void {
  Object.assign(globalConfig, overrides);
}

export function resetConfig(): void {
  globalConfig = { ...DEFAULT_CONFIG };
}

export interface ChainInstance {
  enqueue(cmd: QueuedCommand): void;
  execute(): Promise<unknown>;
  getAssertions(): AssertionResult[];
}

/**
 * Creates a new command chain. Commands are enqueued and later
 * executed sequentially via execute().
 */
export function createChainable(): ChainInstance {
  const queue: QueuedCommand[] = [];
  const assertions: AssertionResult[] = [];

  return {
    enqueue(cmd: QueuedCommand): void {
      queue.push(cmd);
    },

    async execute(): Promise<unknown> {
      let subject: unknown = undefined;
      let lastQueryIndex = -1;

      for (let i = 0; i < queue.length; i++) {
        const cmd = queue[i];

        if (cmd.type === "query") {
          lastQueryIndex = i;
          subject = await cmd.fn(subject);
        } else if (cmd.type === "action") {
          subject = await cmd.fn(subject);
        } else if (cmd.type === "assertion") {
          const timeout = cmd.timeout ?? globalConfig.defaultCommandTimeout;
          const queryIdx = lastQueryIndex;

          if (queryIdx >= 0) {
            const queryCmd = queue[queryIdx];
            const intermediateCommands = queue.slice(queryIdx + 1, i);

            subject = await retry(
              async () => {
                let s: unknown = await queryCmd.fn(undefined);
                for (const mid of intermediateCommands) {
                  if (mid.type === "query") {
                    s = await mid.fn(s);
                  }
                }
                s = await cmd.fn(s);
                return s;
              },
              { timeout, interval: 50 }
            );
          } else {
            subject = await cmd.fn(subject);
          }

          assertions.push({
            description: cmd.name,
            passed: true,
            expected: undefined,
            actual: subject,
          });
        }
      }

      return subject;
    },

    getAssertions(): AssertionResult[] {
      return assertions;
    },
  };
}

// --- CyChain: a fluent wrapper around ChainInstance ---

class CyChain<T> {
  /** @internal */
  _chain: ChainInstance;

  constructor(chain: ChainInstance) {
    this._chain = chain;
  }

  // --- Child queries ---
  find(selector: string): CyChain<Element[]> {
    this._chain.enqueue({ type: "query", name: `find(${selector})`, fn: (subject) => domFind(subject as Element, selector) });
    return this as unknown as CyChain<Element[]>;
  }

  first(): CyChain<Element> {
    this._chain.enqueue({ type: "query", name: "first()", fn: (s) => domFirst(s as Element[]) });
    return this as unknown as CyChain<Element>;
  }

  last(): CyChain<Element> {
    this._chain.enqueue({ type: "query", name: "last()", fn: (s) => domLast(s as Element[]) });
    return this as unknown as CyChain<Element>;
  }

  eq(index: number): CyChain<Element> {
    this._chain.enqueue({ type: "query", name: `eq(${index})`, fn: (s) => domEq(s as Element[], index) });
    return this as unknown as CyChain<Element>;
  }

  // --- Actions ---
  click(): CyChain<T> {
    this._chain.enqueue({ type: "action", name: "click()", fn: (s) => domClick(s as Element) });
    return this;
  }

  type(text: string): CyChain<T> {
    this._chain.enqueue({ type: "action", name: `type(${text})`, fn: (s) => domType(s as Element, text) });
    return this;
  }

  clear(): CyChain<T> {
    this._chain.enqueue({ type: "action", name: "clear()", fn: (s) => domClear(s as Element) });
    return this;
  }

  check(): CyChain<T> {
    this._chain.enqueue({ type: "action", name: "check()", fn: (s) => domCheck(s as Element) });
    return this;
  }

  select(value: string): CyChain<T> {
    this._chain.enqueue({ type: "action", name: `select(${value})`, fn: (s) => domSelect(s as Element, value) });
    return this;
  }

  // --- Assertions ---
  should(matcher: string, ...args: unknown[]): CyChain<T> {
    this._chain.enqueue({
      type: "assertion",
      name: `should(${matcher})`,
      fn: (subject) => {
        const result = applyMatcher(matcher, subject, ...args);
        if (!result.passed) {
          throw new Error(
            `Expected to ${matcher}` +
              (args.length > 0 ? ` ${JSON.stringify(args[0])}` : "") +
              ` but got ${JSON.stringify(result.actual)}`
          );
        }
        return subject;
      },
      timeout: globalConfig.defaultCommandTimeout,
    });
    return this;
  }

  and(matcher: string, ...args: unknown[]): CyChain<T> {
    return this.should(matcher, ...args);
  }

  // --- Utilities ---
  then<U>(fn: (subject: T) => U | CyChain<U>): CyChain<U> {
    this._chain.enqueue({
      type: "action",
      name: "then()",
      fn: (s) => {
        const result = fn(s as T);
        if (result instanceof CyChain) {
          return result._chain.execute();
        }
        return result;
      },
    });
    return this as unknown as CyChain<U>;
  }

  wait(ms: number): CyChain<T> {
    this._chain.enqueue({
      type: "action",
      name: `wait(${ms})`,
      fn: async (s) => {
        await new Promise((r) => setTimeout(r, ms));
        return s;
      },
    });
    return this;
  }

  log(message: string): CyChain<T> {
    this._chain.enqueue({
      type: "action",
      name: `log(${message})`,
      fn: (s) => {
        console.log(`[tauri-cypress] ${message}`, s);
        return s;
      },
    });
    return this;
  }
}

// --- CyGlobal: the top-level cy object ---

function createCyGlobal() {
  let currentChain: ChainInstance | null = null;

  const cy = {
    /** @internal - execute current chain and reset */
    async __run(): Promise<{ result: unknown; assertions: AssertionResult[] }> {
      const chain = currentChain;
      currentChain = null;
      if (!chain) return { result: undefined, assertions: [] };
      const result = await chain.execute();
      return { result, assertions: chain.getAssertions() };
    },

    /** @internal - check if there's a pending chain */
    __hasPendingChain(): boolean {
      return currentChain !== null;
    },

    // --- Queries ---
    get(selector: string, options?: { timeout?: number }): CyChain<Element[]> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({
        type: "query",
        name: `get(${selector})`,
        fn: () => domGet(selector),
        timeout: options?.timeout,
      });
      return new CyChain(chain);
    },

    contains(text: string): CyChain<Element> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({
        type: "query",
        name: `contains(${text})`,
        fn: () => {
          const el = domContains(text);
          if (!el) throw new Error(`No element containing "${text}"`);
          return el;
        },
      });
      return new CyChain(chain);
    },

    // --- Navigation ---
    visit(path: string): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `visit(${path})`, fn: () => navVisit(path) });
      return new CyChain(chain);
    },

    reload(): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: "reload()", fn: () => navReload() });
      return new CyChain(chain);
    },

    url(): CyChain<string> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: "url()", fn: () => navUrl() });
      return new CyChain(chain);
    },

    hash(): CyChain<string> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: "hash()", fn: () => navHash() });
      return new CyChain(chain);
    },

    go(direction: "back" | "forward"): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `go(${direction})`, fn: () => navGo(direction) });
      return new CyChain(chain);
    },

    // --- IPC ---
    mockCommand(name: string, response: unknown): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `mockCommand(${name})`, fn: () => ipcMockCommand(name, response) });
      return new CyChain(chain);
    },

    interceptCommand(name: string, handler: (args: unknown) => unknown): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `interceptCommand(${name})`, fn: () => ipcInterceptCommand(name, handler) });
      return new CyChain(chain);
    },

    clearMocks(): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: "clearMocks()", fn: () => ipcClearMocks() });
      return new CyChain(chain);
    },

    invoke(command: string, args?: unknown): CyChain<unknown> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `invoke(${command})`, fn: () => ipcInvoke(command, args) });
      return new CyChain(chain);
    },

    ipcLog(filter?: string): CyChain<IpcLogEntry[]> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `ipcLog(${filter ?? ""})`, fn: () => ipcGetLog(filter) });
      return new CyChain(chain);
    },

    // --- Rust ---
    rustHelper(name: string, args?: unknown): CyChain<unknown> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `rustHelper(${name})`, fn: () => rustHelperCmd(name, args) });
      return new CyChain(chain);
    },

    appState(key: string): CyChain<unknown> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `appState(${key})`, fn: () => rustAppState(key) });
      return new CyChain(chain);
    },

    // --- Window ---
    window() {
      return {
        resize: (width: number, height: number): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: `window.resize(${width},${height})`, fn: () => winResize(width, height) });
          return new CyChain(chain);
        },
        minimize: (): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: "window.minimize()", fn: () => winMinimize() });
          return new CyChain(chain);
        },
        maximize: (): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: "window.maximize()", fn: () => winMaximize() });
          return new CyChain(chain);
        },
        fullscreen: (enabled?: boolean): CyChain<void> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: `window.fullscreen(${enabled})`, fn: () => winFullscreen(enabled) });
          return new CyChain(chain);
        },
        position: (): CyChain<{ x: number; y: number }> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "query", name: "window.position()", fn: () => winPosition() });
          return new CyChain(chain);
        },
        size: (): CyChain<{ width: number; height: number }> => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "query", name: "window.size()", fn: () => winSize() });
          return new CyChain(chain);
        },
      };
    },

    // --- Snapshot ---
    screenshot(name?: string): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `screenshot(${name ?? ""})`, fn: () => { snapshotScreenshot(name); } });
      return new CyChain(chain);
    },

    snapshot(label: string): CyChain<DomSnapshot> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `snapshot(${label})`, fn: () => snapshotTake(label) });
      return new CyChain(chain);
    },

    // --- Utilities ---
    wait(ms: number): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `wait(${ms})`, fn: () => new Promise((r) => setTimeout(r, ms)) });
      return new CyChain(chain);
    },

    log(message: string): CyChain<void> {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `log(${message})`, fn: () => { console.log(`[tauri-cypress] ${message}`); } });
      return new CyChain(chain);
    },

    // --- Config ---
    config(overrides: Partial<CyConfig>): void {
      setConfig(overrides);
    },
  };

  return cy;
}

export type CyGlobal = ReturnType<typeof createCyGlobal>;

export const cy = createCyGlobal();
