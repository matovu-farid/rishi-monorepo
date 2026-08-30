export type WsCreds =
  | { valid: false; reason: string }
  | { valid: true; jwt: string; reconnectToken?: string; admissionTicket?: string };

/**
 * Decode a base64url-encoded string. Bearer tokens (JWTs, opaque tokens, test
 * bearers) can contain characters that aren't valid in an RFC 6455 WebSocket
 * subprotocol token (notably `:` and whitespace, but also `=`). Callers
 * base64url-encode the bearer before stuffing it into `Sec-WebSocket-Protocol`,
 * and the worker decodes it back here.
 *
 * Returns `null` on malformed input (caller treats as missing).
 */
function decodeBase64Url(input: string): string | null {
  // Restore standard base64 alphabet + padding so atob accepts it.
  const b64 = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  try {
    // atob is available in Workers and modern Node.
    const bin = atob(padded);
    // Re-decode as UTF-8 in case the bearer contains non-ASCII (display names).
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
}

export function parseSubprotocols(headerValue: string | null): WsCreds {
  if (!headerValue) return { valid: false, reason: "missing protocol" };
  const parts = headerValue.split(",").map((s) => s.trim()).filter(Boolean);
  const ok = parts.some((p) => p === "rishi.sharing.v1");
  if (!ok) return { valid: false, reason: "wrong protocol" };
  const jwtEncoded = parts.find((p) => p.startsWith("jwt."))?.slice(4);
  const reconnectEncoded = parts.find((p) => p.startsWith("reconnect."))?.slice(10);
  const admissionTickets = parts.filter((p) => p.startsWith("admission."));
  if (admissionTickets.length > 1) return { valid: false, reason: "multiple admission tickets" };
  if (!jwtEncoded) return { valid: false, reason: "missing jwt" };
  const jwt = decodeBase64Url(jwtEncoded);
  if (jwt === null) return { valid: false, reason: "invalid jwt encoding" };
  let reconnectToken: string | undefined;
  if (reconnectEncoded) {
    const decoded = decodeBase64Url(reconnectEncoded);
    if (decoded === null) return { valid: false, reason: "invalid reconnect encoding" };
    reconnectToken = decoded;
  }
  const admissionTicket = admissionTickets[0]?.slice("admission.".length);
  if (admissionTickets.length === 1 && !admissionTicket) {
    return { valid: false, reason: "missing admission ticket" };
  }
  return { valid: true, jwt, reconnectToken, admissionTicket };
}
