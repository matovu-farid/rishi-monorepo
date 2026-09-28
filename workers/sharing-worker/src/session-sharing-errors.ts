export type SharingFailureStage =
  | "auth.provider"
  | "internal.authorization"
  | "internal.room-command"
  | "turn.credentials"
  | "websocket.room"
  | "internal.room-storage";

export class SharingDependencyFailure extends Error {
  readonly _tag = "SharingDependencyFailure";

  constructor(
    readonly dependency: "auth" | "turn" | "room" | "crypto",
    readonly stage: SharingFailureStage,
    readonly cause: unknown,
  ) {
    super(`${dependency} dependency failed`);
  }
}

export class TurnUnavailableFailure extends Error {
  readonly _tag = "TurnUnavailableFailure";

  constructor(readonly cause?: unknown) {
    super("TURN_UNAVAILABLE");
  }
}

export class InternalAuthorizationFailure extends Error {
  readonly _tag = "InternalAuthorizationFailure";

  constructor(readonly reason: "missing" | "invalid" | "expired" | "claims_mismatch", readonly cause?: unknown) {
    super("invalid internal authorization");
  }
}

export class InvalidInternalCommandFailure extends Error {
  readonly _tag = "InvalidInternalCommandFailure";

  constructor(readonly reason: "invalid_body" | "invalid_action" | "session_mismatch") {
    super("invalid internal command");
  }
}

export class RoomRpcFailure extends Error {
  readonly _tag = "RoomRpcFailure";

  constructor(readonly suppliedCode: unknown, readonly cause: unknown) {
    super("room RPC failed");
  }
}

export function failureTag(error: unknown): string {
  if (error && typeof error === "object" && "_tag" in error && typeof error._tag === "string") {
    return error._tag;
  }
  return "UnexpectedFailure";
}
