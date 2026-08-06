import {
  InsufficientAllowanceError,
  type AllowanceKind,
} from "../durable-objects/user-usage-ledger/errors";

export type InsufficientAllowancePayload = {
  error: string;
  code: "INSUFFICIENT_ALLOWANCE";
  allowance_kind: AllowanceKind;
};

export function getInsufficientAllowancePayload(
  error: unknown,
): InsufficientAllowancePayload | null {
  if (!InsufficientAllowanceError.isInstance(error)) return null;
  const remoteError = typeof error === "object" && error !== null
    ? error as { message?: unknown; allowanceKind?: unknown; allowance_kind?: unknown }
    : {};
  const message = typeof remoteError.message === "string" && remoteError.message.length > 0
    ? remoteError.message
    : "Trial credits are exhausted";
  const markedKind = remoteError.allowanceKind === "trial" || remoteError.allowanceKind === "narration"
    ? remoteError.allowanceKind
    : remoteError.allowance_kind === "trial" || remoteError.allowance_kind === "narration"
      ? remoteError.allowance_kind
      : null;
  const normalizedMessage = message.toLowerCase();
  const allowanceKind: AllowanceKind = markedKind ??
    (normalizedMessage.includes("narration allowance") || normalizedMessage.includes("billing period")
      ? "narration"
      : "trial");
  return { error: message, code: "INSUFFICIENT_ALLOWANCE", allowance_kind: allowanceKind };
}
