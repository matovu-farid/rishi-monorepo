import { Cause, Effect, Exit, Layer, Option } from "effect";
import {
  SessionSharingDependencyFailure,
  SessionSharingDomainFailure,
  SessionSharingFailure,
  SessionSharingInvalidResponseFailure,
  SessionSharingUnexpectedFailure,
  toSessionSharingServiceError,
} from "./session-sharing-errors";
import type { SessionSharingErrorCode } from "./session-sharing-errors";
import {
  makeSessionSharingEffectLayer,
  SessionSharingDiagnostics,
  SessionSharingTransport,
} from "./session-sharing-effect-services";

export {
  SessionSharingServiceError,
  isSessionSharingServiceError,
} from "./session-sharing-errors";
export type { SessionSharingErrorCode } from "./session-sharing-errors";
export type { SessionSharingFailure } from "./session-sharing-errors";

const enc = new TextEncoder();

const DEFAULT_BASE_URL = "https://sharing-worker.internal";
const DEFAULT_TOKEN_TTL_MS = 60_000;

function toBase64Url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importHmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export interface SessionSharingTokenClaims {
  method: "POST";
  path: string;
  body: unknown;
  exp: number;
}

/**
 * Reproduces the sharing-worker's internal HS256 JWT envelope exactly:
 * header `{"alg":"HS256","typ":"JWT"}` and HMAC-SHA256 over
 * `base64url(header).base64url(payload)`.
 */
export async function signInternalToken(
  secret: string,
  claims: SessionSharingTokenClaims,
): Promise<string> {
  const headerB64 = toBase64Url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payloadB64 = toBase64Url(enc.encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${payloadB64}`;
  const sig = await crypto.subtle.sign("HMAC", await importHmacKey(secret), enc.encode(signingInput));
  return `${signingInput}.${toBase64Url(new Uint8Array(sig))}`;
}

function signInternalTokenEffect(
  secret: string,
  claims: SessionSharingTokenClaims,
  correlationId?: string,
): Effect.Effect<string, SessionSharingDependencyFailure | SessionSharingUnexpectedFailure> {
  return Effect.gen(function* () {
    const signingInput = yield* Effect.try({
      try: () => {
        const headerB64 = toBase64Url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
        const payload = JSON.stringify(claims);
        if (payload === undefined) throw new TypeError("Session sharing claims are not serializable");
        const payloadB64 = toBase64Url(enc.encode(payload));
        return `${headerB64}.${payloadB64}`;
      },
      catch: (cause) => new SessionSharingUnexpectedFailure({
        code: "INTERNAL_ERROR",
        message: "Unable to encode session sharing token claims",
        stage: "sign_request",
        correlationId,
        cause,
      }),
    });
    const signature = yield* Effect.tryPromise({
      try: async () => crypto.subtle.sign("HMAC", await importHmacKey(secret), enc.encode(signingInput)),
      catch: (cause) => new SessionSharingDependencyFailure({
        code: "SERVICE_UNAVAILABLE",
        message: "Unable to sign session sharing request",
        stage: "sign_request",
        correlationId,
        cause,
      }),
    });
    return `${signingInput}.${toBase64Url(new Uint8Array(signature))}`;
  });
}

export interface SessionSharingServiceBinding {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

export interface SessionSharingServiceOptions {
  internalTokenSecret: string;
  baseUrl?: string;
  /** Versioned internal route prefix. Legacy callers keep `/internal`. */
  internalPathPrefix?: string;
  tokenTtlMs?: number;
  now?: () => number;
  /** Opaque request identifier propagated to the isolated sharing Worker. */
  correlationId?: string;
}

export interface SessionSharingBookContext {
  contentHash: string;
  bookId?: string;
  format?: "epub" | "pdf";
  [key: string]: unknown;
}

export interface SessionSharingParticipantProfile {
  displayName: string;
  avatarUrl?: string;
}

export interface SessionSharingParticipantStatus {
  userId: string;
  profile: SessionSharingParticipantProfile;
  joinedAt: number;
  bookReady: boolean;
  connectionState: "connected" | "reconnecting";
}

export interface SessionSharingRoomStatus {
  sessionId: string;
  status: "waiting" | "active" | "ended";
  roomEpoch: number;
  controllerGeneration: number;
  controllerUserId: string;
  participants: SessionSharingParticipantStatus[];
  maxParticipants: number;
  removedUserIds: string[];
}

export interface SessionSharingRedeemInfo {
  sessionId: string;
  bookContext: SessionSharingBookContext;
  status: "waiting" | "active" | "ended";
  roomEpoch: number;
}

export interface SessionSharingAdmissionTicketResponse {
  admissionTicket: string;
  claims: {
    kind: "admission";
    sessionId: string;
    inviteId: string;
    userId: string;
    ticketId: string;
    roomEpoch: number;
    connectionGeneration: number;
    exp: number;
  };
  roomEpoch: number;
  status: "waiting" | "active" | "ended";
}

export interface SessionSharingRoomControlState {
  sessionId: string;
  status: "waiting" | "active" | "ended";
  roomEpoch: number;
  controllerGeneration: number;
  controllerUserId: string;
}

export interface SessionSharingCreateRoomRequest {
  sessionId: string;
  initialSharerUserId: string;
  bookContext: SessionSharingBookContext;
  maxParticipants?: number;
}

export interface SessionSharingGetRoomStatusRequest {
  sessionId: string;
}

export interface SessionSharingGetRedeemInfoRequest {
  sessionId: string;
}

export interface SessionSharingIssueAdmissionTicketRequest {
  sessionId: string;
  inviteId: string;
  userId: string;
  contentHash: string;
  profile?: SessionSharingParticipantProfile;
}

export interface SessionSharingStartRoomRequest {
  sessionId: string;
  actingUserId: string;
  expectedControllerGeneration: number;
}

export interface SessionSharingLeaveRoomRequest {
  sessionId: string;
  actingUserId: string;
  deliberate?: boolean;
}

export interface SessionSharingTransferControllerRequest {
  sessionId: string;
  actingUserId: string;
  targetUserId: string;
  expectedControllerGeneration: number;
}

export interface SessionSharingRemoveParticipantRequest {
  sessionId: string;
  actingUserId: string;
  userId: string;
  expectedControllerGeneration: number;
}

export interface SessionSharingRestoreParticipantRequest {
  sessionId: string;
  actingUserId: string;
  userId: string;
  inviteId: string;
  contentHash: string;
  expectedControllerGeneration: number;
  profile?: SessionSharingParticipantProfile;
}

export interface SessionSharingEndRoomRequest {
  sessionId: string;
  actingUserId: string;
  expectedControllerGeneration: number;
}

export interface SessionSharingPurgeRoomRequest {
  sessionId: string;
}

export interface SessionSharingRevokeAccountReferencesRequest {
  sessionId: string;
  accountUserId: string;
  deletionOperationId: string;
}

export type SessionSharingRevokeAccountReferencesResponse = {
  ok: true;
  status: "ended" | "removed" | "not_found";
};

export interface SessionSharingCreateRoomResponse {
  sessionId: string;
  roomEpoch: number;
  controllerGeneration: number;
}

export type SessionSharingRoomStatusResponse = SessionSharingRoomStatus | null;
export type SessionSharingRedeemInfoResponse = SessionSharingRedeemInfo | null;

export interface SessionSharingActionErrorBody {
  code?: string;
  error?: string;
}

const STATUS_CODE_MAP: Record<number, SessionSharingErrorCode> = {
  400: "BAD_REQUEST",
  401: "SERVICE_UNAVAILABLE",
  403: "FORBIDDEN",
  404: "SESSION_NOT_FOUND",
  409: "CONFLICT",
  500: "INTERNAL_ERROR",
  502: "SERVICE_UNAVAILABLE",
  503: "SERVICE_UNAVAILABLE",
  504: "SERVICE_UNAVAILABLE",
};

const RESPONSE_CODE_SET = new Set<SessionSharingErrorCode>([
  "CONFLICT",
  "ALREADY_INITIALIZED",
  "BOOK_HASH_MISMATCH",
  "FORBIDDEN",
  "INVALID_COMMAND",
  "NO_SUCH_PARTICIPANT",
  "REMOVED_FROM_SESSION",
  "ROOM_FULL",
  "SERVICE_UNAVAILABLE",
  "SESSION_ENDED",
  "SESSION_NOT_FOUND",
  "STALE_CONTROLLER_GENERATION",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isOkSentinel(value: unknown): boolean {
  return isRecord(value) && value.ok === true && Object.keys(value).length === 1;
}

function responseCodeFromBody(body: unknown): string | undefined {
  if (!isRecord(body)) return undefined;
  return typeof body.code === "string" && body.code.length > 0 ? body.code : undefined;
}

function responseErrorFromBody(body: unknown): string | undefined {
  if (!isRecord(body)) return undefined;
  return typeof body.error === "string" && body.error.length > 0 ? body.error : undefined;
}

function mapStatus(status: number): SessionSharingErrorCode {
  return STATUS_CODE_MAP[status] ?? "HTTP_ERROR";
}

function mapResponseError(
  status: number,
  body: unknown,
  correlationId?: string,
  cause?: unknown,
): SessionSharingDomainFailure {
  const bodyCode = responseCodeFromBody(body);
  const message = responseErrorFromBody(body) ?? `Session sharing request failed with HTTP ${status}`;
  const code = status < 500 && bodyCode && RESPONSE_CODE_SET.has(bodyCode as SessionSharingErrorCode)
    ? (bodyCode as SessionSharingErrorCode)
    : mapStatus(status);
  return new SessionSharingDomainFailure({
    code,
    message,
    status,
    responseCode: bodyCode,
    cause,
    correlationId,
  });
}

function safeCauseSummary(failure: SessionSharingFailure): string {
  const stage = "stage" in failure ? failure.stage : failure._tag;
  const causeKind = failure.cause === undefined
    ? "no underlying cause"
    : failure.cause instanceof Error
      ? "underlying Error"
      : `underlying ${typeof failure.cause}`;
  return `${failure._tag} at ${stage}; ${causeKind}`;
}

function readJsonResponse(response: Response, correlationId?: string): Effect.Effect<unknown, SessionSharingFailure> {
  return Effect.tryPromise({
    try: () => response.text(),
    catch: (cause) => new SessionSharingDependencyFailure({
      code: "SERVICE_UNAVAILABLE",
      message: "Unable to read session sharing response",
      stage: "read_response",
      correlationId,
      cause,
    }),
  }).pipe(Effect.flatMap((text) => {
    if (text.length === 0) return Effect.succeed(null);
    return Effect.try({
      try: () => JSON.parse(text) as unknown,
      catch: (cause) => new SessionSharingInvalidResponseFailure({
        code: "INVALID_RESPONSE",
        message: "Session sharing service returned invalid JSON",
        status: response.status,
        correlationId,
        cause,
      }),
    });
  }));
}

function roomUrl(baseUrl: string, internalPathPrefix: string, sessionId: string): URL {
  return new URL(`${internalPathPrefix}/rooms/${encodeURIComponent(sessionId)}`, baseUrl);
}

export class SessionSharingService {
  private readonly baseUrl: string;
  private readonly internalPathPrefix: string;
  private readonly tokenTtlMs: number;
  private readonly now: () => number;
  readonly layer: Layer.Layer<SessionSharingTransport | SessionSharingDiagnostics>;

  constructor(
    private readonly binding: SessionSharingServiceBinding,
    private readonly options: SessionSharingServiceOptions,
  ) {
    this.baseUrl = options.baseUrl ?? DEFAULT_BASE_URL;
    this.internalPathPrefix = `/${(options.internalPathPrefix ?? "/internal").replace(/^\/+|\/+$/g, "")}`;
    this.tokenTtlMs = options.tokenTtlMs ?? DEFAULT_TOKEN_TTL_MS;
    this.now = options.now ?? Date.now;
    this.layer = makeSessionSharingEffectLayer(binding, {
      correlationId: options.correlationId,
      sign: (claims) => signInternalTokenEffect(options.internalTokenSecret, claims, options.correlationId),
    });
  }

  createRoomEffect(input: SessionSharingCreateRoomRequest): Effect.Effect<SessionSharingCreateRoomResponse, SessionSharingFailure> {
    return this.requestEffect<SessionSharingCreateRoomResponse>(input.sessionId, "createRoom", {
      sessionId: input.sessionId,
      initialSharerUserId: input.initialSharerUserId,
      bookContext: input.bookContext,
      maxParticipants: input.maxParticipants,
    });
  }

  createRoom(input: SessionSharingCreateRoomRequest): Promise<SessionSharingCreateRoomResponse> {
    return this.runCompatibility(this.createRoomEffect(input));
  }

  getRoomStatusEffect(input: SessionSharingGetRoomStatusRequest): Effect.Effect<SessionSharingRoomStatusResponse, SessionSharingFailure> {
    return this.requestEffect<SessionSharingRoomStatusResponse>(input.sessionId, "getRoomStatus", {});
  }

  getRoomStatus(input: SessionSharingGetRoomStatusRequest): Promise<SessionSharingRoomStatusResponse> {
    return this.runCompatibility(this.getRoomStatusEffect(input));
  }

  getRedeemInfoEffect(input: SessionSharingGetRedeemInfoRequest): Effect.Effect<SessionSharingRedeemInfoResponse, SessionSharingFailure> {
    return this.requestEffect<SessionSharingRedeemInfoResponse>(input.sessionId, "getRedeemInfo", {});
  }

  getRedeemInfo(input: SessionSharingGetRedeemInfoRequest): Promise<SessionSharingRedeemInfoResponse> {
    return this.runCompatibility(this.getRedeemInfoEffect(input));
  }

  issueAdmissionTicketEffect(
    input: SessionSharingIssueAdmissionTicketRequest,
  ): Effect.Effect<SessionSharingAdmissionTicketResponse, SessionSharingFailure> {
    return this.requestEffect<SessionSharingAdmissionTicketResponse>(input.sessionId, "issueAdmissionTicket", {
      inviteId: input.inviteId,
      userId: input.userId,
      contentHash: input.contentHash,
      profile: input.profile,
    });
  }

  issueAdmissionTicket(input: SessionSharingIssueAdmissionTicketRequest): Promise<SessionSharingAdmissionTicketResponse> {
    return this.runCompatibility(this.issueAdmissionTicketEffect(input));
  }

  startRoomEffect(input: SessionSharingStartRoomRequest): Effect.Effect<SessionSharingRoomControlState, SessionSharingFailure> {
    return this.requestEffect<SessionSharingRoomControlState>(input.sessionId, "startRoom", {
      actingUserId: input.actingUserId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  startRoom(input: SessionSharingStartRoomRequest): Promise<SessionSharingRoomControlState> {
    return this.runCompatibility(this.startRoomEffect(input));
  }

  leaveRoomEffect(input: SessionSharingLeaveRoomRequest): Effect.Effect<SessionSharingRoomControlState, SessionSharingFailure> {
    return this.requestEffect<SessionSharingRoomControlState>(input.sessionId, "leaveRoom", {
      actingUserId: input.actingUserId,
      deliberate: input.deliberate,
    });
  }

  leaveRoom(input: SessionSharingLeaveRoomRequest): Promise<SessionSharingRoomControlState> {
    return this.runCompatibility(this.leaveRoomEffect(input));
  }

  transferControllerEffect(input: SessionSharingTransferControllerRequest): Effect.Effect<SessionSharingRoomControlState, SessionSharingFailure> {
    return this.requestEffect<SessionSharingRoomControlState>(input.sessionId, "transferController", {
      actingUserId: input.actingUserId,
      targetUserId: input.targetUserId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  transferController(input: SessionSharingTransferControllerRequest): Promise<SessionSharingRoomControlState> {
    return this.runCompatibility(this.transferControllerEffect(input));
  }

  removeParticipantEffect(input: SessionSharingRemoveParticipantRequest): Effect.Effect<SessionSharingRoomControlState, SessionSharingFailure> {
    return this.requestEffect<SessionSharingRoomControlState>(input.sessionId, "removeParticipant", {
      actingUserId: input.actingUserId,
      userId: input.userId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  removeParticipant(input: SessionSharingRemoveParticipantRequest): Promise<SessionSharingRoomControlState> {
    return this.runCompatibility(this.removeParticipantEffect(input));
  }

  restoreParticipantEffect(input: SessionSharingRestoreParticipantRequest): Effect.Effect<SessionSharingAdmissionTicketResponse, SessionSharingFailure> {
    return this.requestEffect<SessionSharingAdmissionTicketResponse>(input.sessionId, "restoreParticipant", {
      actingUserId: input.actingUserId,
      userId: input.userId,
      inviteId: input.inviteId,
      contentHash: input.contentHash,
      expectedControllerGeneration: input.expectedControllerGeneration,
      profile: input.profile,
    });
  }

  restoreParticipant(input: SessionSharingRestoreParticipantRequest): Promise<SessionSharingAdmissionTicketResponse> {
    return this.runCompatibility(this.restoreParticipantEffect(input));
  }

  endRoomEffect(input: SessionSharingEndRoomRequest): Effect.Effect<SessionSharingRoomControlState, SessionSharingFailure> {
    return this.requestEffect<SessionSharingRoomControlState>(input.sessionId, "endRoom", {
      actingUserId: input.actingUserId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  endRoom(input: SessionSharingEndRoomRequest): Promise<SessionSharingRoomControlState> {
    return this.runCompatibility(this.endRoomEffect(input));
  }

  revokeAccountReferencesEffect(input: SessionSharingRevokeAccountReferencesRequest): Effect.Effect<SessionSharingRevokeAccountReferencesResponse, SessionSharingFailure> {
    return Effect.gen(this, function* () {
      const result = yield* this.requestEffect<unknown>(input.sessionId, "revokeAccountReferences", {
        accountUserId: input.accountUserId,
        deletionOperationId: input.deletionOperationId,
      });
      if (!isRecord(result) || result.ok !== true || !["ended", "removed", "not_found"].includes(String(result.status))) {
        return yield* Effect.fail(new SessionSharingInvalidResponseFailure({
          code: "INVALID_RESPONSE",
          message: "Invalid account revocation acknowledgement",
          correlationId: this.options.correlationId,
        }));
      }
      return result as SessionSharingRevokeAccountReferencesResponse;
    });
  }

  revokeAccountReferences(input: SessionSharingRevokeAccountReferencesRequest): Promise<SessionSharingRevokeAccountReferencesResponse> {
    return this.runCompatibility(this.revokeAccountReferencesEffect(input));
  }

  purgeAppleRoomEffect(input: SessionSharingPurgeRoomRequest): Effect.Effect<{ ok: true }, SessionSharingFailure> {
    return Effect.gen(this, function* () {
      const result = yield* this.requestEffect<unknown>(input.sessionId, "purgeAppleRoom", {}, true);
      if (!isOkSentinel(result)) {
        return yield* Effect.fail(new SessionSharingInvalidResponseFailure({
          code: "INVALID_RESPONSE",
          message: "Invalid room purge acknowledgement",
          correlationId: this.options.correlationId,
        }));
      }
      return { ok: true as const };
    });
  }

  purgeAppleRoom(input: SessionSharingPurgeRoomRequest): Promise<{ ok: true }> {
    return this.runCompatibility(this.purgeAppleRoomEffect(input));
  }

  private runCompatibility<T>(effect: Effect.Effect<T, SessionSharingFailure>): Promise<T> {
    return Effect.runPromiseExit(effect).then((exit) => {
      if (Exit.isSuccess(exit)) return exit.value;
      const failure = Cause.failureOption(exit.cause);
      if (Option.isSome(failure)) throw toSessionSharingServiceError(failure.value);
      throw toSessionSharingServiceError(new SessionSharingUnexpectedFailure({
        code: "INTERNAL_ERROR",
        message: "Unexpected session sharing failure",
        stage: "promise_compatibility",
        correlationId: this.options.correlationId,
        cause: exit.cause,
      }));
    });
  }

  private requestEffect<TResponse>(
    sessionId: string,
    action: string,
    payload: Record<string, unknown>,
    preserveOk = false,
  ): Effect.Effect<TResponse, SessionSharingFailure> {
    const correlationId = this.options.correlationId;
    const work = Effect.gen(this, function* () {
      const transport = yield* SessionSharingTransport;
      const path = `${this.internalPathPrefix}/rooms/${encodeURIComponent(sessionId)}`;
      const body = { action, payload };
      const token = yield* transport.sign({
        method: "POST",
        path,
        body,
        exp: this.now() + this.tokenTtlMs,
      });
      const target = yield* Effect.try({
        try: () => roomUrl(this.baseUrl, this.internalPathPrefix, sessionId),
        catch: (cause) => new SessionSharingUnexpectedFailure({
          code: "INTERNAL_ERROR",
          message: "Unable to construct session sharing request",
          stage: action,
          correlationId,
          cause,
        }),
      });
      const response = yield* transport.fetch(target, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-rishi-internal-token": token,
          ...(correlationId ? { "x-rishi-correlation-id": correlationId } : {}),
        },
        body: yield* Effect.try({
          try: () => JSON.stringify(body),
          catch: (cause) => new SessionSharingUnexpectedFailure({
            code: "INTERNAL_ERROR",
            message: "Unable to encode session sharing request",
            stage: action,
            correlationId,
            cause,
          }),
        }),
      });
      const parsed = yield* readJsonResponse(response, correlationId);
      if (!response.ok) {
        return yield* Effect.fail(mapResponseError(response.status, parsed, correlationId, response));
      }
      if (isOkSentinel(parsed) && !preserveOk) return null as TResponse;
      return parsed as TResponse;
    });

    return Effect.gen(function* () {
      const diagnostics = yield* SessionSharingDiagnostics;
      const startedAt = performance.now();
      const emit = (outcome: "started" | "succeeded" | "failed", failure?: SessionSharingFailure) =>
        diagnostics.emit({
          operation: action,
          stage: action,
          outcome,
          ...(outcome === "started" ? {} : { durationMs: Math.round(performance.now() - startedAt) }),
          ...(failure ? { code: failure.code } : {}),
          ...(failure ? { causeSummary: safeCauseSummary(failure) } : {}),
          ...(failure?.correlationId ?? correlationId ? { correlationId: failure?.correlationId ?? correlationId } : {}),
        });
      yield* emit("started");
      return yield* work.pipe(
        Effect.catchAllDefect((cause) => Effect.fail(new SessionSharingUnexpectedFailure({
          code: "INTERNAL_ERROR",
          message: "Unexpected session sharing failure",
          stage: action,
          correlationId,
          cause,
        }))),
        Effect.tap(() => emit("succeeded")),
        Effect.tapError((failure) => emit("failed", failure)),
      );
    }).pipe(Effect.provide(this.layer));
  }
}

export function createSessionSharingService(
  binding: SessionSharingServiceBinding,
  options: SessionSharingServiceOptions,
): SessionSharingService {
  return new SessionSharingService(binding, options);
}

/**
 * Compensation helper for callers that need to close a room after a failed
 * multi-step flow.
 */
export function endRoom(
  service: SessionSharingService,
  input: SessionSharingEndRoomRequest,
): Promise<SessionSharingRoomControlState> {
  return service.endRoom(input);
}
