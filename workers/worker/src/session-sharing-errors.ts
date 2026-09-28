import { Data } from "effect";

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

export class SessionSharingDomainFailure extends Data.TaggedError("SessionSharingDomainFailure")<{
  readonly code: SessionSharingErrorCode;
  readonly message: string;
  readonly status?: number;
  readonly responseCode?: string;
  readonly correlationId?: string;
  readonly cause?: unknown;
}> {}

export class SessionSharingTransportFailure extends Data.TaggedError("SessionSharingTransportFailure")<{
  readonly code: "NETWORK_ERROR";
  readonly message: string;
  readonly stage: "sign_request" | "fetch" | "read_response";
  readonly correlationId?: string;
  readonly cause: unknown;
}> {}

export class SessionSharingInvalidResponseFailure extends Data.TaggedError("SessionSharingInvalidResponseFailure")<{
  readonly code: "INVALID_RESPONSE";
  readonly message: string;
  readonly status?: number;
  readonly correlationId?: string;
  readonly cause?: unknown;
}> {}

export class SessionSharingDependencyFailure extends Data.TaggedError("SessionSharingDependencyFailure")<{
  readonly code: "SERVICE_UNAVAILABLE";
  readonly message: string;
  readonly stage: string;
  readonly correlationId?: string;
  readonly cause: unknown;
}> {}

export class SessionSharingUnexpectedFailure extends Data.TaggedError("SessionSharingUnexpectedFailure")<{
  readonly code: "INTERNAL_ERROR";
  readonly message: string;
  readonly stage: string;
  readonly correlationId?: string;
  readonly cause: unknown;
}> {}

export type SessionSharingFailure =
  | SessionSharingDomainFailure
  | SessionSharingTransportFailure
  | SessionSharingInvalidResponseFailure
  | SessionSharingDependencyFailure
  | SessionSharingUnexpectedFailure;

export class SessionSharingServiceError extends Error {
  readonly name = "SessionSharingServiceError";

  constructor(
    public readonly code: SessionSharingErrorCode,
    message: string,
    public readonly status?: number,
    public readonly responseCode?: string,
    cause?: unknown,
    public readonly correlationId?: string,
  ) {
    super(message);
    if (cause !== undefined) this.cause = cause;
  }
}

export function isSessionSharingServiceError(error: unknown): error is SessionSharingServiceError {
  return error instanceof SessionSharingServiceError;
}

export function toSessionSharingServiceError(error: SessionSharingFailure): SessionSharingServiceError {
  switch (error._tag) {
    case "SessionSharingDomainFailure":
    case "SessionSharingInvalidResponseFailure":
      return new SessionSharingServiceError(
        error.code,
        error.message,
        error.status,
        error._tag === "SessionSharingDomainFailure" ? error.responseCode : undefined,
        error.cause,
        error.correlationId,
      );
    case "SessionSharingTransportFailure":
    case "SessionSharingDependencyFailure":
    case "SessionSharingUnexpectedFailure":
      return new SessionSharingServiceError(
        error.code,
        error.message,
        undefined,
        undefined,
        error.cause,
        error.correlationId,
      );
  }
}

export function isSessionSharingFailure(error: unknown): error is SessionSharingFailure {
  return error instanceof SessionSharingDomainFailure
    || error instanceof SessionSharingTransportFailure
    || error instanceof SessionSharingInvalidResponseFailure
    || error instanceof SessionSharingDependencyFailure
    || error instanceof SessionSharingUnexpectedFailure;
}
