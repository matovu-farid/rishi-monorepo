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

export interface SessionSharingServiceBinding {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

export interface SessionSharingServiceOptions {
  internalTokenSecret: string;
  baseUrl?: string;
  tokenTtlMs?: number;
  now?: () => number;
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

export type SessionSharingErrorCode =
  | "ALREADY_INITIALIZED"
  | "BAD_REQUEST"
  | "BOOK_HASH_MISMATCH"
  | "CONFLICT"
  | "FORBIDDEN"
  | "HTTP_ERROR"
  | "INTERNAL_ERROR"
  | "INVALID_COMMAND"
  | "INVALID_RESPONSE"
  | "NETWORK_ERROR"
  | "NO_SUCH_PARTICIPANT"
  | "REMOVED_FROM_SESSION"
  | "ROOM_FULL"
  | "SERVICE_UNAVAILABLE"
  | "SESSION_ENDED"
  | "SESSION_NOT_FOUND"
  | "STALE_CONTROLLER_GENERATION";

export class SessionSharingServiceError extends Error {
  readonly name = "SessionSharingServiceError";

  constructor(
    public readonly code: SessionSharingErrorCode,
    message: string,
    public readonly status?: number,
    public readonly responseCode?: string,
    cause?: unknown,
  ) {
    super(message);
    if (cause !== undefined) this.cause = cause;
  }
}

export function isSessionSharingServiceError(error: unknown): error is SessionSharingServiceError {
  return error instanceof SessionSharingServiceError;
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
  cause?: unknown,
): SessionSharingServiceError {
  const bodyCode = responseCodeFromBody(body);
  const message = responseErrorFromBody(body) ?? `Session sharing request failed with HTTP ${status}`;
  const code = bodyCode && RESPONSE_CODE_SET.has(bodyCode as SessionSharingErrorCode)
    ? (bodyCode as SessionSharingErrorCode)
    : mapStatus(status);
  return new SessionSharingServiceError(code, message, status, bodyCode, cause);
}

async function readJsonResponse(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.length === 0) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch (cause) {
    throw new SessionSharingServiceError(
      "INVALID_RESPONSE",
      "Session sharing service returned invalid JSON",
      response.status,
      undefined,
      cause,
    );
  }
}

function roomUrl(baseUrl: string, sessionId: string): URL {
  return new URL(`/internal/rooms/${encodeURIComponent(sessionId)}`, baseUrl);
}

export class SessionSharingService {
  private readonly baseUrl: string;
  private readonly tokenTtlMs: number;
  private readonly now: () => number;

  constructor(
    private readonly binding: SessionSharingServiceBinding,
    private readonly options: SessionSharingServiceOptions,
  ) {
    this.baseUrl = options.baseUrl ?? DEFAULT_BASE_URL;
    this.tokenTtlMs = options.tokenTtlMs ?? DEFAULT_TOKEN_TTL_MS;
    this.now = options.now ?? Date.now;
  }

  async createRoom(input: SessionSharingCreateRoomRequest): Promise<SessionSharingCreateRoomResponse> {
    return this.request<SessionSharingCreateRoomResponse>(input.sessionId, "createRoom", {
      initialSharerUserId: input.initialSharerUserId,
      bookContext: input.bookContext,
      maxParticipants: input.maxParticipants,
    });
  }

  async getRoomStatus(input: SessionSharingGetRoomStatusRequest): Promise<SessionSharingRoomStatusResponse> {
    return this.request<SessionSharingRoomStatusResponse>(input.sessionId, "getRoomStatus", {});
  }

  async getRedeemInfo(input: SessionSharingGetRedeemInfoRequest): Promise<SessionSharingRedeemInfoResponse> {
    return this.request<SessionSharingRedeemInfoResponse>(input.sessionId, "getRedeemInfo", {});
  }

  async issueAdmissionTicket(
    input: SessionSharingIssueAdmissionTicketRequest,
  ): Promise<SessionSharingAdmissionTicketResponse> {
    return this.request<SessionSharingAdmissionTicketResponse>(input.sessionId, "issueAdmissionTicket", {
      inviteId: input.inviteId,
      userId: input.userId,
      contentHash: input.contentHash,
      profile: input.profile,
    });
  }

  async startRoom(input: SessionSharingStartRoomRequest): Promise<SessionSharingRoomControlState> {
    return this.request<SessionSharingRoomControlState>(input.sessionId, "startRoom", {
      actingUserId: input.actingUserId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  async leaveRoom(input: SessionSharingLeaveRoomRequest): Promise<SessionSharingRoomControlState> {
    return this.request<SessionSharingRoomControlState>(input.sessionId, "leaveRoom", {
      actingUserId: input.actingUserId,
      deliberate: input.deliberate,
    });
  }

  async transferController(input: SessionSharingTransferControllerRequest): Promise<SessionSharingRoomControlState> {
    return this.request<SessionSharingRoomControlState>(input.sessionId, "transferController", {
      actingUserId: input.actingUserId,
      targetUserId: input.targetUserId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  async removeParticipant(input: SessionSharingRemoveParticipantRequest): Promise<SessionSharingRoomControlState> {
    return this.request<SessionSharingRoomControlState>(input.sessionId, "removeParticipant", {
      actingUserId: input.actingUserId,
      userId: input.userId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  async restoreParticipant(input: SessionSharingRestoreParticipantRequest): Promise<SessionSharingAdmissionTicketResponse> {
    return this.request<SessionSharingAdmissionTicketResponse>(input.sessionId, "restoreParticipant", {
      actingUserId: input.actingUserId,
      userId: input.userId,
      inviteId: input.inviteId,
      contentHash: input.contentHash,
      expectedControllerGeneration: input.expectedControllerGeneration,
      profile: input.profile,
    });
  }

  async endRoom(input: SessionSharingEndRoomRequest): Promise<SessionSharingRoomControlState> {
    return this.request<SessionSharingRoomControlState>(input.sessionId, "endRoom", {
      actingUserId: input.actingUserId,
      expectedControllerGeneration: input.expectedControllerGeneration,
    });
  }

  private async request<TResponse>(
    sessionId: string,
    action: string,
    payload: Record<string, unknown>,
  ): Promise<TResponse> {
    const path = `/internal/rooms/${encodeURIComponent(sessionId)}`;
    const body = { action, payload };
    const token = await signInternalToken(this.options.internalTokenSecret, {
      method: "POST",
      path,
      body,
      exp: this.now() + this.tokenTtlMs,
    });

    let response: Response;
    try {
      response = await this.binding.fetch(roomUrl(this.baseUrl, sessionId), {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-rishi-internal-token": token,
        },
        body: JSON.stringify(body),
      });
    } catch (cause) {
      throw new SessionSharingServiceError(
        "NETWORK_ERROR",
        "Session sharing service fetch failed",
        undefined,
        undefined,
        cause,
      );
    }

    const parsed = await readJsonResponse(response);
    if (!response.ok) {
      throw mapResponseError(response.status, parsed, response);
    }

    if (isOkSentinel(parsed)) {
      return null as TResponse;
    }
    return parsed as TResponse;
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
