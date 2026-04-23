/**
 * Polyfills for older WebKit/WebView versions.
 *
 * Tauri uses the system WebView: WebKit (Safari) on macOS, WebView2 (Chromium)
 * on Windows. Older macOS versions ship older Safari engines that lack newer
 * Web APIs used by our dependencies (pdfjs-dist v5, openai SDK, etc.).
 *
 * This file MUST be imported before any library code.
 */

/* eslint-disable @typescript-eslint/no-explicit-any */

// ---------------------------------------------------------------------------
// URL.parse() — Safari 18+
// Used by: pdfjs-dist v5.x (6 call sites)
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
// Promise.withResolvers() — Safari 18.2+
// Used by: pdfjs-dist v5.x (30+ call sites) — most critical polyfill
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
// structuredClone() — Safari 15.4+
// Used by: pdfjs-dist, openai SDK
// ---------------------------------------------------------------------------
if (typeof (globalThis as any).structuredClone !== "function") {
  (globalThis as any).structuredClone = function <T>(value: T): T {
    return JSON.parse(JSON.stringify(value));
  };
}

// ---------------------------------------------------------------------------
// Object.hasOwn() — Safari 15.4+
// Used by: openai SDK
// ---------------------------------------------------------------------------
if (typeof (Object as any).hasOwn !== "function") {
  (Object as any).hasOwn = function (obj: object, prop: PropertyKey): boolean {
    return Object.prototype.hasOwnProperty.call(obj, prop);
  };
}

// ---------------------------------------------------------------------------
// crypto.randomUUID() — Safari 15.4+
// Used by: our code (useChat, highlight-storage, bookmark-storage),
//          pdfjs-dist, openai SDK
// ---------------------------------------------------------------------------
if (typeof crypto.randomUUID !== "function") {
  (crypto as any).randomUUID = function (): string {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  };
}

// ---------------------------------------------------------------------------
// AbortSignal.timeout() — Safari 16+
// Used by: openai SDK
// ---------------------------------------------------------------------------
if (typeof (AbortSignal as any).timeout !== "function") {
  (AbortSignal as any).timeout = function (ms: number): AbortSignal {
    const controller = new AbortController();
    setTimeout(() => controller.abort(new DOMException("TimeoutError", "TimeoutError")), ms);
    return controller.signal;
  };
}

// ---------------------------------------------------------------------------
// Array.prototype.at() — Safari 15.4+
// Used by: pdfjs-dist (15 call sites), openai SDK
// ---------------------------------------------------------------------------
if (typeof ([] as any).at !== "function") {
  (Array.prototype as any).at = function <T>(this: T[], index: number): T | undefined {
    const i = index >= 0 ? index : this.length + index;
    return this[i];
  };
}
if (typeof ("" as any).at !== "function") {
  (String.prototype as any).at = function (this: string, index: number): string | undefined {
    const i = index >= 0 ? index : this.length + index;
    return this[i];
  };
}

export {};
