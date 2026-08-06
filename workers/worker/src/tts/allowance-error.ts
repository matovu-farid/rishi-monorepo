import type { AllowanceKind } from "../durable-objects/user-usage-ledger/errors";

export type InsufficientAllowancePayload = {
  error: string;
  code: "INSUFFICIENT_ALLOWANCE";
  allowance_kind: AllowanceKind;
};

type AllowanceSignal = {
  message?: string;
  allowanceKind?: AllowanceKind;
};

function isAllowanceMessage(message: string): boolean {
  const normalized = message.toLowerCase();
  return (
    normalized.includes("trial credits are exhausted") ||
    normalized.includes("narration allowance is exhausted")
  );
}

function allowanceKind(value: unknown): AllowanceKind | undefined {
  return value === "trial" || value === "narration" ? value : undefined;
}

/**
 * Durable Object RPC can rehydrate a thrown custom Error as a plain Error,
 * dropping its subclass name and custom `code` property. Keep the explicit
 * marker as the primary signal, but accept the stable exhaustion messages as
 * a compatibility signal so the route can still return the typed 402 body.
 */
function findAllowanceSignal(error: unknown): AllowanceSignal | null {
  const seen = new Set<object>();
  const visit = (value: unknown): AllowanceSignal | null => {
    if (value === null || value === undefined) return null;
    if (typeof value === "string") {
      return isAllowanceMessage(value) ? { message: value } : null;
    }
    if (typeof value !== "object") return null;
    if (seen.has(value)) return null;
    seen.add(value);

    const record = value as {
      name?: unknown;
      code?: unknown;
      message?: unknown;
      allowanceKind?: unknown;
      allowance_kind?: unknown;
      cause?: unknown;
      error?: unknown;
    };
    const message = typeof record.message === "string" ? record.message : undefined;
    const marked =
      record.code === "INSUFFICIENT_ALLOWANCE" ||
      record.name === "InsufficientAllowanceError";
    const kind = allowanceKind(record.allowanceKind) ?? allowanceKind(record.allowance_kind);
    if (marked || (message !== undefined && isAllowanceMessage(message))) {
      return { message, allowanceKind: kind };
    }

    return visit(record.cause) ?? visit(record.error);
  };

  return visit(error);
}

export function getInsufficientAllowancePayload(
  error: unknown,
): InsufficientAllowancePayload | null {
  const signal = findAllowanceSignal(error);
  if (!signal) return null;

  const message = signal.message && signal.message.length > 0
    ? signal.message
    : "Trial credits are exhausted";
  const markedKind = signal.allowanceKind;
  const normalizedMessage = message.toLowerCase();
  const allowanceKind: AllowanceKind = markedKind ??
    (normalizedMessage.includes("narration allowance") || normalizedMessage.includes("billing period")
      ? "narration"
      : "trial");
  return { error: message, code: "INSUFFICIENT_ALLOWANCE", allowance_kind: allowanceKind };
}
