import { Context, Effect, Layer } from "effect";
import {
  InternalAuthorizationFailure,
  SharingDependencyFailure,
  type SharingFailureStage,
} from "./session-sharing-errors";
import { verify } from "./hmac";
import { issueAdmissionTicket, verifyAdmissionTicket } from "./tokens";

export class AppleRoomStorage extends Context.Tag("AppleRoomStorage")<
  AppleRoomStorage,
  {
    readonly get: <A>(key: string) => Effect.Effect<A | undefined, SharingDependencyFailure>;
    readonly put: <A>(key: string, value: A) => Effect.Effect<void, SharingDependencyFailure>;
    readonly delete: (key: string) => Effect.Effect<boolean, SharingDependencyFailure>;
    readonly setAlarm: (scheduledTime: number) => Effect.Effect<void, SharingDependencyFailure>;
    readonly deleteAlarm: () => Effect.Effect<void, SharingDependencyFailure>;
    readonly transaction: <A>(body: (txn: {
      get<B>(key: string): Promise<B | undefined>;
      put<B>(key: string, value: B): Promise<void>;
    }) => Promise<A>) => Effect.Effect<A, unknown>;
  }
>() {}

export class AppleRoomRuntime extends Context.Tag("AppleRoomRuntime")<
  AppleRoomRuntime,
  {
    readonly now: () => number;
    readonly randomUUID: () => string;
    readonly issueAdmissionTicket: (input: Parameters<typeof issueAdmissionTicket>[0], secret: string) => Effect.Effect<Awaited<ReturnType<typeof issueAdmissionTicket>>, SharingDependencyFailure>;
    readonly verifyAdmissionTicket: (token: string, secret: string) => Effect.Effect<Awaited<ReturnType<typeof verifyAdmissionTicket>>, Error>;
  }
>() {}

export type AppleRoomDiagnostic = {
  readonly event: "apple.room.command_failed";
  readonly operation: string;
  readonly stage: "auth.provider" | "internal.room-command" | "internal.room-storage" | "websocket.room";
  readonly outcome: "error";
  readonly code: string;
  readonly causeCodes?: readonly string[];
  readonly correlationId?: string;
  readonly durationMs: number;
  readonly causeKind: "typed_failure" | "defect_or_interruption";
};

export class AppleRoomDiagnostics extends Context.Tag("AppleRoomDiagnostics")<
  AppleRoomDiagnostics,
  { readonly emit: (diagnostic: AppleRoomDiagnostic) => Effect.Effect<void> }
>() {}

export function makeAppleRoomLayer(
  storage: {
    get<A>(key: string): Promise<A | undefined>;
    put<A>(key: string, value: A): Promise<void>;
    delete(key: string): Promise<boolean>;
    setAlarm(scheduledTime: number): Promise<void>;
    deleteAlarm(): Promise<void>;
    transaction<A>(body: (txn: { get<B>(key: string): Promise<B | undefined>; put<B>(key: string, value: B): Promise<void> }) => Promise<A>): Promise<A>;
  },
  emit: (diagnostic: AppleRoomDiagnostic) => void,
): Layer.Layer<AppleRoomStorage | AppleRoomRuntime | AppleRoomDiagnostics> {
  return Layer.mergeAll(
    Layer.succeed(AppleRoomStorage, {
      get: <A>(key: string) => Effect.tryPromise({
        try: () => storage.get<A>(key),
        catch: (cause) => new SharingDependencyFailure("room", "internal.room-storage", cause),
      }),
      put: <A>(key: string, value: A) => Effect.tryPromise({
        try: () => storage.put(key, value),
        catch: (cause) => new SharingDependencyFailure("room", "internal.room-storage", cause),
      }),
      delete: (key: string) => Effect.tryPromise({
        try: () => storage.delete(key),
        catch: (cause) => new SharingDependencyFailure("room", "internal.room-storage", cause),
      }),
      setAlarm: (scheduledTime: number) => Effect.tryPromise({
        try: () => storage.setAlarm(scheduledTime),
        catch: (cause) => new SharingDependencyFailure("room", "internal.room-storage", cause),
      }),
      deleteAlarm: () => Effect.tryPromise({
        try: () => storage.deleteAlarm(),
        catch: (cause) => new SharingDependencyFailure("room", "internal.room-storage", cause),
      }),
      transaction: <A>(body: (txn: { get<B>(key: string): Promise<B | undefined>; put<B>(key: string, value: B): Promise<void> }) => Promise<A>) => Effect.tryPromise({
        try: () => storage.transaction(body),
        catch: (cause) => cause,
      }),
    }),
    Layer.succeed(AppleRoomRuntime, {
      now: () => Date.now(),
      randomUUID: () => crypto.randomUUID(),
      issueAdmissionTicket: (input, secret) => Effect.tryPromise({
        try: () => issueAdmissionTicket(input, secret),
        catch: (cause) => new SharingDependencyFailure("crypto", "internal.room-command", cause),
      }),
      verifyAdmissionTicket: (token, secret) => Effect.tryPromise({
        try: () => verifyAdmissionTicket(token, secret),
        catch: (cause) => cause instanceof Error ? cause : new Error("invalid admission ticket"),
      }),
    }),
    Layer.succeed(AppleRoomDiagnostics, {
      emit: (diagnostic) => Effect.sync(() => emit(diagnostic)),
    }),
  );
}

export type SignedInternalClaims = { method: string; path: string; body: unknown; exp: number };

export class SharingHttpClient extends Context.Tag("SharingHttpClient")<
  SharingHttpClient,
  {
    readonly fetch: (
      input: RequestInfo | URL,
      init?: RequestInit,
      stage?: SharingFailureStage,
      dependency?: SharingDependencyFailure["dependency"],
    ) => Effect.Effect<Response, SharingDependencyFailure>;
  }
>() {}

export class AuthIdentityLookup extends Context.Tag("AuthIdentityLookup")<
  AuthIdentityLookup,
  {
    readonly lookup: (authorization: string) => Effect.Effect<Response, SharingDependencyFailure, SharingHttpClient>;
  }
>() {}

export class LegacyAuthSessionLookup extends Context.Tag("LegacyAuthSessionLookup")<
  LegacyAuthSessionLookup,
  {
    readonly lookup: (authorization: string) => Effect.Effect<Response, SharingDependencyFailure, SharingHttpClient>;
  }
>() {}

export class TurnCredentialProvider extends Context.Tag("TurnCredentialProvider")<
  TurnCredentialProvider,
  {
    readonly issue: (input: {
      keyId: string;
      apiToken: string;
      ttlSeconds: number;
    }) => Effect.Effect<Response, SharingDependencyFailure, SharingHttpClient>;
  }
>() {}

export class InternalCommandVerifier extends Context.Tag("InternalCommandVerifier")<
  InternalCommandVerifier,
  {
    readonly verify: (token: string, secret: string) => Effect.Effect<SignedInternalClaims, InternalAuthorizationFailure>;
  }
>() {}

export type SharingDiagnostic = {
  readonly event: "sharing.request.failed" | "sharing.turn.provider_failure" | "sharing.internal.command";
  readonly correlationId?: string;
  readonly operation: string;
  readonly stage: SharingFailureStage;
  readonly outcome: "error";
  readonly code: string;
  readonly status?: number;
  readonly causeKind?: "typed_failure" | "defect_or_interruption";
};

export class SharingDiagnostics extends Context.Tag("SharingDiagnostics")<
  SharingDiagnostics,
  { readonly emit: (diagnostic: SharingDiagnostic) => Effect.Effect<void> }
>() {}

export interface SharingWorkerBindings {
  readonly AUTH_BASE_URL: string;
  readonly TURN_KEY_ID?: string;
  readonly TURN_API_TOKEN?: string;
}

export function makeSharingWorkerLayer(
  bindings: SharingWorkerBindings,
  fetcher: typeof fetch = fetch,
): Layer.Layer<SharingHttpClient | AuthIdentityLookup | LegacyAuthSessionLookup | TurnCredentialProvider | InternalCommandVerifier | SharingDiagnostics> {
  const httpClient = Layer.succeed(SharingHttpClient, {
    fetch: (input: RequestInfo | URL, init?: RequestInit, stage: SharingFailureStage = "internal.room-command", dependency: SharingDependencyFailure["dependency"] = "room") =>
      Effect.tryPromise({
        try: () => fetcher(input, init),
        catch: (cause) => new SharingDependencyFailure(dependency, stage, cause),
      }),
  });
  const authIdentityLookup = Layer.effect(AuthIdentityLookup, Effect.gen(function* () {
    const http = yield* SharingHttpClient;
    return {
      lookup: (authorization: string) => http.fetch(
        `${bindings.AUTH_BASE_URL}/api/v1/reading-sessions/auth-context`,
        { headers: { authorization, accept: "application/json" } },
        "auth.provider",
        "auth",
      ),
    };
  }));
  const legacyAuthSessionLookup = Layer.effect(LegacyAuthSessionLookup, Effect.gen(function* () {
    const http = yield* SharingHttpClient;
    return {
      lookup: (authorization: string) => http.fetch(
        `${bindings.AUTH_BASE_URL}/api/auth/get-session`,
        { headers: { authorization, accept: "application/json" } },
        "auth.provider",
        "auth",
      ),
    };
  }));
  const turnCredentialProvider = Layer.effect(TurnCredentialProvider, Effect.gen(function* () {
    const http = yield* SharingHttpClient;
    return {
      issue: ({ keyId, apiToken, ttlSeconds }: { keyId: string; apiToken: string; ttlSeconds: number }) => http.fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`,
        {
          method: "POST",
          headers: { authorization: `Bearer ${apiToken}`, "content-type": "application/json" },
          body: JSON.stringify({ ttl: ttlSeconds }),
        },
        "turn.credentials",
        "turn",
      ),
    };
  }));

  return Layer.mergeAll(
    httpClient,
    Layer.provide(httpClient)(authIdentityLookup),
    Layer.provide(httpClient)(legacyAuthSessionLookup),
    Layer.provide(httpClient)(turnCredentialProvider),
    Layer.succeed(InternalCommandVerifier, {
      verify: (token, secret) => Effect.tryPromise({
        try: () => verify<SignedInternalClaims>(token, secret),
        catch: (cause) => new InternalAuthorizationFailure("invalid", cause),
      }),
    }),
    Layer.succeed(SharingDiagnostics, {
      emit: (diagnostic) => Effect.sync(() => {
        console.warn(JSON.stringify(diagnostic));
      }),
    }),
  );
}

export function summarizeDiagnosticCause(cause: { readonly _tag?: string }): SharingDiagnostic["causeKind"] {
  return cause._tag === "Fail" ? "typed_failure" : "defect_or_interruption";
}
