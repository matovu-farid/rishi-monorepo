"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/index.ts
var index_exports = {};
__export(index_exports, {
  addCustomMatcher: () => addCustomMatcher,
  afterEach: () => afterEach,
  beforeEach: () => beforeEach,
  createTestRunner: () => createTestRunner,
  cy: () => cy,
  describe: () => describe,
  it: () => it,
  matcherRegistry: () => matcherRegistry
});
module.exports = __toCommonJS(index_exports);

// src/commands/dom.ts
function domGet(selector) {
  return Array.from(document.querySelectorAll(selector));
}
function domContains(text) {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
  let node = walker.nextNode();
  while (node) {
    const el = node;
    if (el.textContent?.trim() === text.trim()) {
      return el;
    }
    node = walker.nextNode();
  }
  return null;
}
function domFind(parent, selector) {
  return Array.from(parent.querySelectorAll(selector));
}
function domFirst(elements) {
  if (elements.length === 0) throw new Error("cy.first() requires at least one element");
  return elements[0];
}
function domLast(elements) {
  if (elements.length === 0) throw new Error("cy.last() requires at least one element");
  return elements[elements.length - 1];
}
function domEq(elements, index) {
  if (index < 0 || index >= elements.length) {
    throw new Error(`cy.eq(${index}): index out of bounds (${elements.length} elements)`);
  }
  return elements[index];
}
function domClick(el) {
  el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  return el;
}
function domType(el, text) {
  const input = el;
  input.value = text;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}
function domClear(el) {
  const input = el;
  input.value = "";
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}
function domCheck(el) {
  const input = el;
  input.checked = !input.checked;
  input.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}
function domSelect(el, value) {
  const select = el;
  select.value = value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return el;
}

// src/commands/navigation.ts
function navVisit(path) {
  window.location.href = path;
}
function navReload() {
  window.location.reload();
}
function navUrl() {
  return window.location.href;
}
function navHash() {
  return window.location.hash;
}
function navGo(direction) {
  if (direction === "back") {
    window.history.back();
  } else {
    window.history.forward();
  }
}

// src/bridge.ts
function getTauriCypress() {
  if (typeof window === "undefined" || !window.__tauriCypress) {
    throw new Error(
      "tauri-cypress: __tauriCypress not found. Is tauri-plugin-test-harness loaded?"
    );
  }
  return window.__tauriCypress;
}
var bridge = {
  mockCommand(name, response) {
    getTauriCypress().bridge.mockCommand(name, response);
  },
  interceptCommand(name, handler) {
    getTauriCypress().bridge.interceptCommand(name, handler);
  },
  removeMock(name) {
    getTauriCypress().bridge.removeMock(name);
  },
  clearMocks() {
    getTauriCypress().bridge.clearMocks();
  },
  getState(key) {
    return getTauriCypress().bridge.getState(key);
  },
  callHelper(name, args) {
    return getTauriCypress().bridge.callHelper(name, args ?? null);
  },
  getIpcLog() {
    return getTauriCypress().ipc.log;
  },
  takeSnapshot(label) {
    return getTauriCypress().snapshot.take(label);
  },
  getSnapshotHistory() {
    return getTauriCypress().snapshot.history;
  },
  invoke(cmd, args) {
    return getTauriCypress().bridge.invoke(cmd, args);
  }
};

// src/commands/ipc.ts
function ipcMockCommand(name, response) {
  bridge.mockCommand(name, response);
}
function ipcInterceptCommand(name, handler) {
  bridge.interceptCommand(name, handler);
}
function ipcClearMocks() {
  bridge.clearMocks();
}
async function ipcInvoke(command, args) {
  return bridge.invoke(command, args);
}
function ipcGetLog(filter) {
  const log = bridge.getIpcLog();
  if (!filter) return log;
  return log.filter((entry) => entry.command === filter);
}

// src/commands/rust.ts
async function rustHelper(name, args) {
  return bridge.callHelper(name, args);
}
async function rustAppState(key) {
  return bridge.getState(key);
}

// src/commands/window.ts
async function winResize(width, height) {
  await bridge.invoke("plugin:test-harness|resize_window", { width, height });
}
async function winMinimize() {
  await bridge.invoke("plugin:test-harness|minimize_window");
}
async function winMaximize() {
  await bridge.invoke("plugin:test-harness|maximize_window");
}
async function winFullscreen(enabled = true) {
  await bridge.invoke("plugin:test-harness|fullscreen_window", { fullscreen: enabled });
}
async function winPosition() {
  return bridge.invoke("plugin:test-harness|get_window_position");
}
async function winSize() {
  return bridge.invoke("plugin:test-harness|get_window_size");
}

// src/commands/snapshot.ts
function snapshotTake(label) {
  return bridge.takeSnapshot(label);
}
function snapshotScreenshot(name) {
  return bridge.takeSnapshot(name ?? `screenshot-${Date.now()}`);
}

// src/assertions/matchers.ts
var matcherRegistry = /* @__PURE__ */ new Map();
function deepEqual(a, b) {
  if (a === b) return true;
  if (a == null || b == null) return false;
  if (typeof a !== typeof b) return false;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((val, i) => deepEqual(val, b[i]));
  }
  if (typeof a === "object" && typeof b === "object") {
    const aObj = a;
    const bObj = b;
    const aKeys = Object.keys(aObj);
    const bKeys = Object.keys(bObj);
    if (aKeys.length !== bKeys.length) return false;
    return aKeys.every((key) => deepEqual(aObj[key], bObj[key]));
  }
  return false;
}
matcherRegistry.set("exist", (subject) => ({
  passed: subject != null,
  actual: subject,
  expected: "to exist"
}));
matcherRegistry.set("be.visible", (subject) => {
  const el = subject;
  if (!el || !el.getClientRects) {
    return { passed: false, actual: null, expected: "to be visible" };
  }
  const style = window.getComputedStyle(el);
  const visible = style.display !== "none" && style.visibility !== "hidden" && el.getClientRects().length > 0;
  return {
    passed: visible,
    actual: visible ? "visible" : "hidden",
    expected: "visible"
  };
});
matcherRegistry.set("be.hidden", (subject) => {
  const visibleResult = matcherRegistry.get("be.visible")(subject);
  return {
    passed: !visibleResult.passed,
    actual: visibleResult.actual,
    expected: "hidden"
  };
});
matcherRegistry.set("be.disabled", (subject) => {
  const el = subject;
  return { passed: el?.disabled === true, actual: el?.disabled, expected: true };
});
matcherRegistry.set("be.enabled", (subject) => {
  const el = subject;
  return {
    passed: el?.disabled === false,
    actual: !el?.disabled,
    expected: true
  };
});
matcherRegistry.set("be.checked", (subject) => {
  const el = subject;
  return { passed: el?.checked === true, actual: el?.checked, expected: true };
});
matcherRegistry.set("have.text", (subject, expected) => {
  const el = subject;
  const actual = el?.textContent ?? "";
  return { passed: actual === expected, actual, expected };
});
matcherRegistry.set("contain.text", (subject, expected) => {
  const el = subject;
  const actual = el?.textContent ?? "";
  return {
    passed: actual.includes(expected),
    actual,
    expected
  };
});
matcherRegistry.set("have.value", (subject, expected) => {
  const el = subject;
  const actual = el?.value;
  return { passed: actual === expected, actual, expected };
});
matcherRegistry.set("have.class", (subject, className) => {
  const el = subject;
  const has = el?.classList?.contains(className) ?? false;
  return { passed: has, actual: el?.className, expected: className };
});
matcherRegistry.set("have.attr", (subject, attrName, attrValue) => {
  const el = subject;
  const actual = el?.getAttribute(attrName);
  if (attrValue === void 0) {
    return {
      passed: actual !== null,
      actual,
      expected: `attribute ${attrName}`
    };
  }
  return { passed: actual === attrValue, actual, expected: attrValue };
});
matcherRegistry.set("have.css", (subject, prop, value) => {
  const el = subject;
  const actual = window.getComputedStyle(el).getPropertyValue(prop);
  return { passed: actual === value, actual, expected: value };
});
matcherRegistry.set("have.length", (subject, expected) => {
  const arr = subject;
  const actual = arr?.length ?? 0;
  return { passed: actual === expected, actual, expected };
});
matcherRegistry.set("include", (subject, value) => {
  if (Array.isArray(subject)) {
    const found = subject.some((item) => deepEqual(item, value));
    return { passed: found, actual: subject, expected: value };
  }
  if (typeof subject === "string") {
    const found = subject.includes(value);
    return { passed: found, actual: subject, expected: value };
  }
  return { passed: false, actual: subject, expected: value };
});
matcherRegistry.set("equal", (subject, expected) => ({
  passed: deepEqual(subject, expected),
  actual: subject,
  expected
}));
matcherRegistry.set("have.property", (subject, prop, value) => {
  const obj = subject;
  const has = obj != null && prop in obj;
  if (!has) {
    return { passed: false, actual: void 0, expected: prop };
  }
  if (value === void 0) {
    return { passed: true, actual: obj[prop], expected: prop };
  }
  const actual = obj[prop];
  return { passed: deepEqual(actual, value), actual, expected: value };
});
function applyMatcher(matcherStr, subject, ...args) {
  const negated = matcherStr.startsWith("not.");
  const key = negated ? matcherStr.slice(4) : matcherStr;
  const matcher = matcherRegistry.get(key);
  if (!matcher) {
    throw new Error(`tauri-cypress: unknown matcher "${key}"`);
  }
  const result = matcher(subject, ...args);
  if (negated) {
    return { ...result, passed: !result.passed };
  }
  return result;
}

// src/retry.ts
var DEFAULTS = {
  timeout: 4e3,
  interval: 50
};
async function retry(fn, options) {
  const { timeout, interval } = { ...DEFAULTS, ...options };
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return await fn();
    } catch (err) {
      lastError = err instanceof Error ? err : new Error(String(err));
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      await new Promise((r) => setTimeout(r, Math.min(interval, remaining)));
    }
  }
  throw lastError ?? new Error(`Timed out after ${timeout}ms`);
}

// src/cy.ts
var DEFAULT_CONFIG = {
  defaultCommandTimeout: 4e3,
  execTimeout: 6e4
};
var globalConfig = { ...DEFAULT_CONFIG };
function setConfig(overrides) {
  Object.assign(globalConfig, overrides);
}
function createChainable() {
  const queue = [];
  const assertions = [];
  return {
    enqueue(cmd) {
      queue.push(cmd);
    },
    async execute() {
      let subject = void 0;
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
                let s = await queryCmd.fn(void 0);
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
            expected: void 0,
            actual: subject
          });
        }
      }
      return subject;
    },
    getAssertions() {
      return assertions;
    }
  };
}
var CyChain = class _CyChain {
  /** @internal */
  _chain;
  constructor(chain) {
    this._chain = chain;
  }
  // --- Child queries ---
  find(selector) {
    this._chain.enqueue({ type: "query", name: `find(${selector})`, fn: (subject) => domFind(subject, selector) });
    return this;
  }
  first() {
    this._chain.enqueue({ type: "query", name: "first()", fn: (s) => domFirst(s) });
    return this;
  }
  last() {
    this._chain.enqueue({ type: "query", name: "last()", fn: (s) => domLast(s) });
    return this;
  }
  eq(index) {
    this._chain.enqueue({ type: "query", name: `eq(${index})`, fn: (s) => domEq(s, index) });
    return this;
  }
  // --- Actions ---
  click() {
    this._chain.enqueue({ type: "action", name: "click()", fn: (s) => domClick(s) });
    return this;
  }
  type(text) {
    this._chain.enqueue({ type: "action", name: `type(${text})`, fn: (s) => domType(s, text) });
    return this;
  }
  clear() {
    this._chain.enqueue({ type: "action", name: "clear()", fn: (s) => domClear(s) });
    return this;
  }
  check() {
    this._chain.enqueue({ type: "action", name: "check()", fn: (s) => domCheck(s) });
    return this;
  }
  select(value) {
    this._chain.enqueue({ type: "action", name: `select(${value})`, fn: (s) => domSelect(s, value) });
    return this;
  }
  // --- Assertions ---
  should(matcher, ...args) {
    this._chain.enqueue({
      type: "assertion",
      name: `should(${matcher})`,
      fn: (subject) => {
        const result = applyMatcher(matcher, subject, ...args);
        if (!result.passed) {
          throw new Error(
            `Expected to ${matcher}` + (args.length > 0 ? ` ${JSON.stringify(args[0])}` : "") + ` but got ${JSON.stringify(result.actual)}`
          );
        }
        return subject;
      },
      timeout: globalConfig.defaultCommandTimeout
    });
    return this;
  }
  and(matcher, ...args) {
    return this.should(matcher, ...args);
  }
  // --- Utilities ---
  then(fn) {
    this._chain.enqueue({
      type: "action",
      name: "then()",
      fn: (s) => {
        const result = fn(s);
        if (result instanceof _CyChain) {
          return result._chain.execute();
        }
        return result;
      }
    });
    return this;
  }
  wait(ms) {
    this._chain.enqueue({
      type: "action",
      name: `wait(${ms})`,
      fn: async (s) => {
        await new Promise((r) => setTimeout(r, ms));
        return s;
      }
    });
    return this;
  }
  log(message) {
    this._chain.enqueue({
      type: "action",
      name: `log(${message})`,
      fn: (s) => {
        console.log(`[tauri-cypress] ${message}`, s);
        return s;
      }
    });
    return this;
  }
};
function createCyGlobal() {
  let currentChain = null;
  const cy2 = {
    /** @internal - execute current chain and reset */
    async __run() {
      const chain = currentChain;
      currentChain = null;
      if (!chain) return { result: void 0, assertions: [] };
      const result = await chain.execute();
      return { result, assertions: chain.getAssertions() };
    },
    /** @internal - check if there's a pending chain */
    __hasPendingChain() {
      return currentChain !== null;
    },
    // --- Queries ---
    get(selector, options) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({
        type: "query",
        name: `get(${selector})`,
        fn: () => domGet(selector),
        timeout: options?.timeout
      });
      return new CyChain(chain);
    },
    contains(text) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({
        type: "query",
        name: `contains(${text})`,
        fn: () => {
          const el = domContains(text);
          if (!el) throw new Error(`No element containing "${text}"`);
          return el;
        }
      });
      return new CyChain(chain);
    },
    // --- Navigation ---
    visit(path) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `visit(${path})`, fn: () => navVisit(path) });
      return new CyChain(chain);
    },
    reload() {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: "reload()", fn: () => navReload() });
      return new CyChain(chain);
    },
    url() {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: "url()", fn: () => navUrl() });
      return new CyChain(chain);
    },
    hash() {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: "hash()", fn: () => navHash() });
      return new CyChain(chain);
    },
    go(direction) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `go(${direction})`, fn: () => navGo(direction) });
      return new CyChain(chain);
    },
    // --- IPC ---
    mockCommand(name, response) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `mockCommand(${name})`, fn: () => ipcMockCommand(name, response) });
      return new CyChain(chain);
    },
    interceptCommand(name, handler) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `interceptCommand(${name})`, fn: () => ipcInterceptCommand(name, handler) });
      return new CyChain(chain);
    },
    clearMocks() {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: "clearMocks()", fn: () => ipcClearMocks() });
      return new CyChain(chain);
    },
    invoke(command, args) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `invoke(${command})`, fn: () => ipcInvoke(command, args) });
      return new CyChain(chain);
    },
    ipcLog(filter) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `ipcLog(${filter ?? ""})`, fn: () => ipcGetLog(filter) });
      return new CyChain(chain);
    },
    // --- Rust ---
    rustHelper(name, args) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `rustHelper(${name})`, fn: () => rustHelper(name, args) });
      return new CyChain(chain);
    },
    appState(key) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `appState(${key})`, fn: () => rustAppState(key) });
      return new CyChain(chain);
    },
    // --- Window ---
    window() {
      return {
        resize: (width, height) => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: `window.resize(${width},${height})`, fn: () => winResize(width, height) });
          return new CyChain(chain);
        },
        minimize: () => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: "window.minimize()", fn: () => winMinimize() });
          return new CyChain(chain);
        },
        maximize: () => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: "window.maximize()", fn: () => winMaximize() });
          return new CyChain(chain);
        },
        fullscreen: (enabled) => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "action", name: `window.fullscreen(${enabled})`, fn: () => winFullscreen(enabled) });
          return new CyChain(chain);
        },
        position: () => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "query", name: "window.position()", fn: () => winPosition() });
          return new CyChain(chain);
        },
        size: () => {
          const chain = createChainable();
          currentChain = chain;
          chain.enqueue({ type: "query", name: "window.size()", fn: () => winSize() });
          return new CyChain(chain);
        }
      };
    },
    // --- Snapshot ---
    screenshot(name) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `screenshot(${name ?? ""})`, fn: () => {
        snapshotScreenshot(name);
      } });
      return new CyChain(chain);
    },
    snapshot(label) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "query", name: `snapshot(${label})`, fn: () => snapshotTake(label) });
      return new CyChain(chain);
    },
    // --- Utilities ---
    wait(ms) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `wait(${ms})`, fn: () => new Promise((r) => setTimeout(r, ms)) });
      return new CyChain(chain);
    },
    log(message) {
      const chain = createChainable();
      currentChain = chain;
      chain.enqueue({ type: "action", name: `log(${message})`, fn: () => {
        console.log(`[tauri-cypress] ${message}`);
      } });
      return new CyChain(chain);
    },
    // --- Config ---
    config(overrides) {
      setConfig(overrides);
    }
  };
  return cy2;
}
var cy = createCyGlobal();

// src/runner.ts
function createTestRunner() {
  const rootBlocks = [];
  const blockStack = [];
  function currentBlock() {
    return blockStack.length > 0 ? blockStack[blockStack.length - 1] : null;
  }
  function describe2(name, fn) {
    const block = {
      name,
      tests: [],
      beforeEachFns: [],
      afterEachFns: [],
      children: []
    };
    const parent = currentBlock();
    if (parent) {
      parent.children.push(block);
    } else {
      rootBlocks.push(block);
    }
    blockStack.push(block);
    fn();
    blockStack.pop();
  }
  function it2(name, fn) {
    const block = currentBlock();
    if (!block) throw new Error("it() must be called inside describe()");
    block.tests.push({ name, fn });
  }
  function beforeEach2(fn) {
    const block = currentBlock();
    if (!block) throw new Error("beforeEach() must be called inside describe()");
    block.beforeEachFns.push(fn);
  }
  function afterEach2(fn) {
    const block = currentBlock();
    if (!block) throw new Error("afterEach() must be called inside describe()");
    block.afterEachFns.push(fn);
  }
  async function runBlock(block, parentPath, parentBeforeEach, parentAfterEach, onResult) {
    const results = [];
    const path = parentPath ? `${parentPath} > ${block.name}` : block.name;
    const allBeforeEach = [...parentBeforeEach, ...block.beforeEachFns];
    const allAfterEach = [...block.afterEachFns, ...parentAfterEach];
    for (const test of block.tests) {
      const testId = `${path} > ${test.name}`;
      const startTime = Date.now();
      let result;
      try {
        for (const hook of allBeforeEach) {
          await hook();
        }
        await test.fn();
        result = {
          testId,
          status: "passed",
          assertions: [],
          error: null,
          durationMs: Date.now() - startTime
        };
      } catch (err) {
        result = {
          testId,
          status: "failed",
          assertions: [],
          error: err instanceof Error ? err.message : String(err),
          durationMs: Date.now() - startTime
        };
      } finally {
        for (const hook of allAfterEach) {
          try {
            await hook();
          } catch {
          }
        }
      }
      results.push(result);
      onResult?.(result);
    }
    for (const child of block.children) {
      const childResults = await runBlock(child, path, allBeforeEach, allAfterEach, onResult);
      results.push(...childResults);
    }
    return results;
  }
  async function run(onResult) {
    const allResults = [];
    for (const block of rootBlocks) {
      const results = await runBlock(block, "", [], [], onResult);
      allResults.push(...results);
    }
    return allResults;
  }
  return { describe: describe2, it: it2, beforeEach: beforeEach2, afterEach: afterEach2, run };
}

// src/index.ts
var defaultRunner = createTestRunner();
var describe = defaultRunner.describe;
var it = defaultRunner.it;
var beforeEach = defaultRunner.beforeEach;
var afterEach = defaultRunner.afterEach;
function addCustomMatcher(name, fn) {
  matcherRegistry.set(name, fn);
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  addCustomMatcher,
  afterEach,
  beforeEach,
  createTestRunner,
  cy,
  describe,
  it,
  matcherRegistry
});
//# sourceMappingURL=index.cjs.map