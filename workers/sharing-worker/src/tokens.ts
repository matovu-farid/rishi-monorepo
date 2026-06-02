import { sign, verify } from "./hmac";

export interface JoinTokenPayload {
  kind: "join";
  sessionId: string;
  issuedAt: number;
  expiresAt: number;
  jti: string;
}

export interface ReconnectTokenPayload {
  kind: "reconnect";
  sessionId: string;
  userId: string;
  reservedUntil: number;
}

export async function issueJoinToken(input: { sessionId: string; ttlMs: number }, secret: string) {
  const now = Date.now();
  const payload: JoinTokenPayload = {
    kind: "join",
    sessionId: input.sessionId,
    issuedAt: now,
    expiresAt: now + input.ttlMs,
    jti: crypto.randomUUID(),
  };
  const token = await sign(payload, secret);
  return { token, payload };
}

export async function verifyJoinToken(token: string, secret: string): Promise<JoinTokenPayload> {
  const p = await verify<JoinTokenPayload>(token, secret);
  if (p.kind !== "join") throw new Error("invalid token kind");
  if (p.expiresAt <= Date.now()) throw new Error("token expired");
  return p;
}

export async function issueReconnectToken(input: { sessionId: string; userId: string; reservedUntil: number }, secret: string) {
  const payload: ReconnectTokenPayload = { kind: "reconnect", ...input };
  return sign(payload, secret);
}

export async function verifyReconnectToken(token: string, secret: string): Promise<ReconnectTokenPayload> {
  const p = await verify<ReconnectTokenPayload>(token, secret);
  if (p.kind !== "reconnect") throw new Error("invalid token kind");
  if (p.reservedUntil <= Date.now()) throw new Error("token expired");
  return p;
}
