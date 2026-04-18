/**
 * Dev-only central error dump.
 *
 * Captures unhandled errors, promise rejections, and manual reports,
 * forwarding them to the Rust backend which writes to error-dump.json.
 */
import { invoke } from "@tauri-apps/api/core";

const IS_DEV = import.meta.env.DEV;

interface DumpErrorParams {
  source: string;
  location: string;
  error: string;
  context?: string;
  stack?: string;
}

/** Send an error to the dump file (no-op in production). */
export function dumpError(params: DumpErrorParams): void {
  if (!IS_DEV) return;
  invoke("dump_error_cmd", params as unknown as Record<string, unknown>).catch(
    () => {
      // Last resort: if the IPC call itself fails, log to console
      console.warn("[error-dump] Failed to write error to dump file", params);
    },
  );
}

/** Install global error handlers that forward to the dump. */
export function installErrorDumpHandlers(): void {
  if (!IS_DEV) return;

  // Unhandled JS errors
  window.addEventListener("error", (event) => {
    dumpError({
      source: "frontend",
      location: event.filename
        ? `${event.filename}:${event.lineno}:${event.colno}`
        : "unknown",
      error: event.message,
      stack: event.error?.stack,
    });
  });

  // Unhandled promise rejections
  window.addEventListener("unhandledrejection", (event) => {
    const reason = event.reason;
    const error =
      reason instanceof Error ? reason.message : String(reason ?? "Unknown");
    const stack = reason instanceof Error ? reason.stack : undefined;
    dumpError({
      source: "frontend",
      location: "unhandledrejection",
      error,
      stack,
    });
  });

  // Intercept console.error to also dump
  const originalConsoleError = console.error;
  console.error = (...args: unknown[]) => {
    originalConsoleError.apply(console, args);
    const message = args
      .map((a) => {
        if (a instanceof Error) return a.message;
        if (typeof a === "string") return a;
        try {
          return JSON.stringify(a);
        } catch {
          return String(a);
        }
      })
      .join(" ");

    const firstError = args.find((a) => a instanceof Error) as
      | Error
      | undefined;

    dumpError({
      source: "frontend",
      location: "console.error",
      error: message,
      stack: firstError?.stack,
    });
  };
}
