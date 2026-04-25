/**
 * Polyfills for older browser engines.
 *
 * Electron uses Chromium which is generally up-to-date, but we include
 * these polyfills for consistency with the Tauri app and to guard against
 * edge cases with older Electron versions.
 *
 * This file MUST be imported before any library code.
 */

/* eslint-disable @typescript-eslint/no-explicit-any */

// ---------------------------------------------------------------------------
// URL.parse() -- Chrome 120+
// Used by: pdfjs-dist v5.x
// ---------------------------------------------------------------------------
if (typeof (URL as any).parse !== "function") {
  (URL as any).parse = function (url: string, base?: string | URL): URL | null {
    try {
      return new URL(url, base);
    } catch {
      return null;
    }
  };
}

// ---------------------------------------------------------------------------
// Promise.withResolvers() -- Chrome 119+
// Used by: pdfjs-dist v5.x (30+ call sites) -- most critical polyfill
// ---------------------------------------------------------------------------
if (typeof (Promise as any).withResolvers !== "function") {
  (Promise as any).withResolvers = function <T>() {
    let resolve!: (value: T | PromiseLike<T>) => void;
    let reject!: (reason?: unknown) => void;
    const promise = new Promise<T>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    return { promise, resolve, reject };
  };
}

// ---------------------------------------------------------------------------
// structuredClone() -- Chrome 98+
// Used by: pdfjs-dist, openai SDK
// ---------------------------------------------------------------------------
if (typeof (globalThis as any).structuredClone !== "function") {
  (globalThis as any).structuredClone = function <T>(value: T): T {
    return JSON.parse(JSON.stringify(value));
  };
}

// ---------------------------------------------------------------------------
// Object.hasOwn() -- Chrome 93+
// Used by: openai SDK
// ---------------------------------------------------------------------------
if (typeof (Object as any).hasOwn !== "function") {
  (Object as any).hasOwn = function (obj: object, prop: PropertyKey): boolean {
    return Object.prototype.hasOwnProperty.call(obj, prop);
  };
}

export {};
