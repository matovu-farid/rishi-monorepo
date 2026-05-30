export type WsCreds =
  | { valid: false; reason: string }
  | { valid: true; jwt: string; reconnectToken?: string };

export function parseSubprotocols(headerValue: string | null): WsCreds {
  if (!headerValue) return { valid: false, reason: "missing protocol" };
  const parts = headerValue.split(",").map((s) => s.trim()).filter(Boolean);
  const ok = parts.some((p) => p === "rishi.sharing.v1");
  if (!ok) return { valid: false, reason: "wrong protocol" };
  const jwt = parts.find((p) => p.startsWith("jwt."))?.slice(4);
  const reconnect = parts.find((p) => p.startsWith("reconnect."))?.slice(10);
  if (!jwt) return { valid: false, reason: "missing jwt" };
  return { valid: true, jwt, reconnectToken: reconnect };
}
