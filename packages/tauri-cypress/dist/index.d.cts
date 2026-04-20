/** Result of a single assertion */
interface AssertionResult {
    description: string;
    passed: boolean;
    expected: unknown;
    actual: unknown;
}
/** IPC log entry from the Rust plugin */
interface IpcLogEntry {
    command: string;
    args: unknown;
    response: unknown;
    mocked: boolean;
    duration_ms: number;
    timestamp_ms: number;
}
/** DOM snapshot captured by the Rust plugin */
interface DomSnapshot {
    label: string;
    html: string;
    url: string;
    timestamp_ms: number;
}
/** Global configuration for cy commands */
interface CyConfig {
    defaultCommandTimeout: number;
    execTimeout: number;
}
/** A matcher function that checks a subject against expected values */
type MatcherFn = (subject: unknown, ...args: unknown[]) => {
    passed: boolean;
    actual: unknown;
    expected: unknown;
};
/**
 * Represents a queued command in the chain.
 * - "query" commands are retryable (get, find, first, etc.)
 * - "action" commands execute once (click, type, visit, etc.)
 * - "assertion" commands trigger retry of preceding query (should, and)
 */
type CommandType = "query" | "action" | "assertion";
interface QueuedCommand {
    type: CommandType;
    name: string;
    fn: (subject: unknown) => unknown | Promise<unknown>;
    timeout?: number;
}
/** The __tauriCypress global injected by the Rust plugin */
interface TauriCypressGlobal {
    bridge: {
        mockCommand: (name: string, response: unknown) => void;
        interceptCommand: (name: string, handler: (args: unknown) => unknown) => void;
        removeMock: (name: string) => void;
        clearMocks: () => void;
        getState: (key: string) => Promise<unknown>;
        callHelper: (name: string, args: unknown) => Promise<unknown>;
    };
    ipc: {
        intercept: (name: string, handler: (args: unknown) => unknown) => void;
        passthrough: (name: string) => void;
        readonly log: IpcLogEntry[];
    };
    snapshot: {
        take: (label: string) => DomSnapshot;
        readonly history: DomSnapshot[];
    };
    __exec: (script: string, testId: string) => Promise<void>;
    waitForReady(): Promise<void>;
}
declare global {
    interface Window {
        __tauriCypress: TauriCypressGlobal;
        __TAURI_INTERNALS__: {
            invoke: (cmd: string, args?: unknown, options?: unknown) => Promise<unknown>;
        };
    }
}

interface ChainInstance {
    enqueue(cmd: QueuedCommand): void;
    execute(): Promise<unknown>;
    getAssertions(): AssertionResult[];
}
declare class CyChain<T> {
    /** @internal */
    _chain: ChainInstance;
    constructor(chain: ChainInstance);
    find(selector: string): CyChain<Element[]>;
    first(): CyChain<Element>;
    last(): CyChain<Element>;
    eq(index: number): CyChain<Element>;
    click(): CyChain<T>;
    type(text: string): CyChain<T>;
    clear(): CyChain<T>;
    check(): CyChain<T>;
    select(value: string): CyChain<T>;
    should(matcher: string, ...args: unknown[]): CyChain<T>;
    and(matcher: string, ...args: unknown[]): CyChain<T>;
    then<U>(fn: (subject: T) => U | CyChain<U>): CyChain<U>;
    wait(ms: number): CyChain<T>;
    log(message: string): CyChain<T>;
}
declare const cy: {
    /** @internal - execute current chain and reset */
    __run(): Promise<{
        result: unknown;
        assertions: AssertionResult[];
    }>;
    /** @internal - check if there's a pending chain */
    __hasPendingChain(): boolean;
    get(selector: string, options?: {
        timeout?: number;
    }): CyChain<Element[]>;
    contains(text: string): CyChain<Element>;
    visit(path: string): CyChain<void>;
    reload(): CyChain<void>;
    url(): CyChain<string>;
    hash(): CyChain<string>;
    go(direction: "back" | "forward"): CyChain<void>;
    mockCommand(name: string, response: unknown): CyChain<void>;
    interceptCommand(name: string, handler: (args: unknown) => unknown): CyChain<void>;
    clearMocks(): CyChain<void>;
    invoke(command: string, args?: unknown): CyChain<unknown>;
    ipcLog(filter?: string): CyChain<IpcLogEntry[]>;
    rustHelper(name: string, args?: unknown): CyChain<unknown>;
    appState(key: string): CyChain<unknown>;
    window(): {
        resize: (width: number, height: number) => CyChain<void>;
        minimize: () => CyChain<void>;
        maximize: () => CyChain<void>;
        fullscreen: (enabled?: boolean) => CyChain<void>;
        position: () => CyChain<{
            x: number;
            y: number;
        }>;
        size: () => CyChain<{
            width: number;
            height: number;
        }>;
    };
    screenshot(name?: string): CyChain<void>;
    snapshot(label: string): CyChain<DomSnapshot>;
    wait(ms: number): CyChain<void>;
    log(message: string): CyChain<void>;
    config(overrides: Partial<CyConfig>): void;
};

interface TestRunnerResult {
    testId: string;
    status: "passed" | "failed" | "skipped";
    assertions: {
        description: string;
        passed: boolean;
        expected: unknown;
        actual: unknown;
    }[];
    error: string | null;
    durationMs: number;
}
declare function createTestRunner(): {
    describe: (name: string, fn: () => void) => void;
    it: (name: string, fn: () => void | Promise<void>) => void;
    beforeEach: (fn: () => void | Promise<void>) => void;
    afterEach: (fn: () => void | Promise<void>) => void;
    run: (onResult?: (result: TestRunnerResult) => void) => Promise<TestRunnerResult[]>;
};

declare const matcherRegistry: Map<string, MatcherFn>;

declare const describe: (name: string, fn: () => void) => void;
declare const it: (name: string, fn: () => void | Promise<void>) => void;
declare const beforeEach: (fn: () => void | Promise<void>) => void;
declare const afterEach: (fn: () => void | Promise<void>) => void;
/**
 * Register a custom assertion matcher.
 *
 * Usage:
 *   addCustomMatcher('have.data', (subject, key, value) => {
 *     const el = subject as HTMLElement;
 *     const actual = el.dataset[key as string];
 *     return {
 *       passed: value === undefined ? actual !== undefined : actual === value,
 *       actual,
 *       expected: value ?? 'data-' + key + ' to exist',
 *     };
 *   });
 */
declare function addCustomMatcher(name: string, fn: (subject: unknown, ...args: unknown[]) => {
    passed: boolean;
    actual: unknown;
    expected: unknown;
}): void;

export { type AssertionResult, type CyConfig, type DomSnapshot, type IpcLogEntry, type MatcherFn, type TauriCypressGlobal, addCustomMatcher, afterEach, beforeEach, createTestRunner, cy, describe, it, matcherRegistry };
