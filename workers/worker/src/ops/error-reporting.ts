import * as Sentry from "@sentry/cloudflare";

const TELEMETRY_FIELDS = [
  "feature",
  "operation",
  "stage",
  "error_code",
  "error_type",
  "provider",
  "http_status",
  "response_mode",
  "cache_result",
  "request_chars",
  "audio_generation",
  "correlation_id",
  "first_chunk_ms",
  "duration_ms",
  "chunk_count",
  "byte_count",
  "cancel_reason",
  "interruption_reason",
  "audio_route",
] as const;

type TelemetryField = (typeof TELEMETRY_FIELDS)[number];
export type WorkerTelemetry = Partial<Record<TelemetryField, string | number>>;

export function sanitizeWorkerTelemetry(
  input: Record<string, unknown>,
): WorkerTelemetry {
  const sanitized: WorkerTelemetry = {};

  for (const field of TELEMETRY_FIELDS) {
    const value = input[field];
    if (
      (typeof value === "string" && value.length > 0) ||
      (typeof value === "number" && Number.isFinite(value))
    ) {
      sanitized[field] = value;
    }
  }

  return sanitized;
}

export function captureWorkerTelemetryError(
  _error: unknown,
  input: Record<string, unknown>,
): void {
  try {
    const telemetry = sanitizeWorkerTelemetry(input);
    const operation =
      typeof telemetry.operation === "string"
        ? telemetry.operation
        : "worker operation";
    const sanitizedError = new Error(`${operation} failed`);
    sanitizedError.name = "RishiWorkerTelemetryError";
    if (_error instanceof Error && typeof _error.stack === "string") {
      const frames = _error.stack
        .split("\n")
        .slice(1)
        .filter((line) => /^\s+at\s/.test(line));
      if (frames.length > 0) {
        sanitizedError.stack = `${sanitizedError.name}: ${sanitizedError.message}\n${frames.join("\n")}`;
      }
    }
    Sentry.withIsolationScope((scope) => {
      if (typeof telemetry.feature === "string") {
        scope.setTag("feature", telemetry.feature);
      }
      for (const key of ["operation", "stage", "error_code", "provider"] as const) {
        const value = telemetry[key];
        if (typeof value === "string") scope.setTag(key, value);
      }
      scope.setContext("telemetry", telemetry);
      let captureException: unknown;
      try {
        captureException = Sentry.captureException;
      } catch {
        captureException = undefined;
      }
      if (typeof captureException === "function") {
        captureException(sanitizedError);
      } else {
        const client = (
          Sentry as typeof Sentry & {
            getClient?: () => {
              captureException: (
                error: Error,
                hint?: unknown,
                scope?: unknown,
              ) => void;
            } | undefined;
          }
        ).getClient?.();
        client?.captureException(sanitizedError, undefined, scope);
      }
    });
  } catch {
    // Telemetry is best effort and must not affect the request.
  }
}
