import { sign, verify } from "./hmac";
import { AdmissionTicketClaims } from "./schemas";
import type { z } from "zod";

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

export type AdmissionTicketClaimsT = z.infer<typeof AdmissionTicketClaims>;

export interface AdmissionTicketInput {
  sessionId: string;
  inviteId: string;
  userId: string;
  ticketId: string;
  roomEpoch: number;
  connectionGeneration: number;
  ttlMs: number;
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

/**
 * Admission tickets are deliberately a distinct token family. The prefix is
 * part of the WebSocket subprotocol value, so a reconnect token can never be
 * accidentally accepted as an Apple admission credential.
 */
export async function issueAdmissionTicket(input: AdmissionTicketInput, secret: string) {
  const claims: AdmissionTicketClaimsT = {
    kind: "admission",
    sessionId: input.sessionId,
    inviteId: input.inviteId,
    userId: input.userId,
    ticketId: input.ticketId,
    roomEpoch: input.roomEpoch,
    connectionGeneration: input.connectionGeneration,
    exp: Date.now() + input.ttlMs,
  };
  return {
    token: `admission.${await sign(claims, secret)}`,
    claims,
  };
}

export async function verifyAdmissionTicket(token: string, secret: string): Promise<AdmissionTicketClaimsT> {
  if (!token.startsWith("admission.")) throw new Error("invalid admission ticket prefix");
  const signed = token.slice("admission.".length);
  if (!signed) throw new Error("missing admission ticket");
  const claims = AdmissionTicketClaims.parse(await verify<unknown>(signed, secret));
  if (claims.exp <= Date.now()) throw new Error("admission ticket expired");
  return claims;
}
