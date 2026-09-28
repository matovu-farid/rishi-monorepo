import { Context, Effect, Layer } from "effect";
import {
  SessionSharingTransportFailure,
} from "./session-sharing-errors";
import type { SessionSharingFailure } from "./session-sharing-errors";
import type { SessionSharingTokenClaims } from "./session-sharing-service";

export interface SessionSharingDiagnosticEvent {
  readonly operation: string;
  readonly stage: string;
  readonly outcome: "started" | "succeeded" | "failed";
  readonly durationMs?: number;
  readonly code?: string;
  readonly causeSummary?: string;
  readonly correlationId?: string;
}

export class SessionSharingTransport extends Context.Tag("SessionSharingTransport")<
  SessionSharingTransport,
  {
    readonly sign: (claims: SessionSharingTokenClaims) => Effect.Effect<string, SessionSharingFailure>;
    readonly fetch: (input: RequestInfo | URL, init?: RequestInit) => Effect.Effect<Response, SessionSharingTransportFailure>;
  }
>() {}

export class SessionSharingDiagnostics extends Context.Tag("SessionSharingDiagnostics")<
  SessionSharingDiagnostics,
  {
    readonly emit: (event: SessionSharingDiagnosticEvent) => Effect.Effect<void>;
  }
>() {}

export interface SessionSharingEffectOptions {
  readonly correlationId?: string;
  readonly sign: (claims: SessionSharingTokenClaims) => Effect.Effect<string, SessionSharingFailure>;
}

export interface SessionSharingServiceBinding {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

export function makeSessionSharingEffectLayer(
  binding: SessionSharingServiceBinding,
  options: SessionSharingEffectOptions,
  emit: (event: SessionSharingDiagnosticEvent) => void = (event) => {
    const line = JSON.stringify({ subsystem: "shared-reading", ...event });
    if (event.outcome === "failed") console.error(line);
    else console.info(line);
  },
): Layer.Layer<SessionSharingTransport | SessionSharingDiagnostics> {
  const transport = Layer.succeed(SessionSharingTransport, {
    sign: options.sign,
    fetch: (input, init) => Effect.tryPromise({
      try: () => binding.fetch(input, init),
      catch: (cause) => new SessionSharingTransportFailure({
        code: "NETWORK_ERROR",
        message: "Session sharing service fetch failed",
        stage: "fetch",
        correlationId: options.correlationId,
        cause,
      }),
    }),
  });
  const diagnostics = Layer.succeed(SessionSharingDiagnostics, {
    emit: (event) => Effect.sync(() => emit(event)).pipe(Effect.catchAllCause(() => Effect.void)),
  });
  return Layer.merge(transport, diagnostics);
}
