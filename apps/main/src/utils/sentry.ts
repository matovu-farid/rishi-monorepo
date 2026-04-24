import * as Sentry from "@sentry/browser";
import {
  defaultOptions,
} from "tauri-plugin-sentry-api";

let _initialized = false;

/**
 * Initialize the Sentry browser SDK so frontend errors are forwarded
 * to the Rust Sentry SDK via the tauri-plugin-sentry IPC transport.
 */
export function initSentry() {
  if (_initialized) return;
  _initialized = true;

  Sentry.init({
    ...defaultOptions,
    tracesSampleRate: 0.1,
    sendDefaultPii: false,
  });
}

/**
 * Capture an error to Sentry with optional structured context.
 * Use this for import failures, IPC errors, and other operational errors
 * that should be visible in the Sentry dashboard.
 */
export function captureError(
  error: unknown,
  context?: {
    operation?: string;
    filePath?: string;
    format?: string;
    step?: string;
    [key: string]: unknown;
  }
) {
  const err =
    error instanceof Error ? error : new Error(String(error));

  Sentry.withScope((scope) => {
    if (context) {
      scope.setContext("import", context);
      if (context.operation) scope.setTag("operation", context.operation);
      if (context.format) scope.setTag("book.format", context.format);
      if (context.step) scope.setTag("import.step", context.step);
    }
    Sentry.captureException(err);
  });
}
