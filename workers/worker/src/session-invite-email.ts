import { and, eq } from "drizzle-orm";
import { sessionInviteDeliveries, type SessionInviteDelivery } from "./db/schema";
import type { WorkerDb } from "./db/drizzle";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_RECIPIENTS = 20;

export type SessionInviteEmailResult = {
  attempted: number;
  sent: number;
  failed: number;
  results: Array<{ email: string; status: "sent" | "failed" | "already_sent"; errorCode?: string }>;
};

export type SessionInviteEmailOptions = {
  db: WorkerDb;
  sessionId: string;
  inviteId: string;
  shareUrl: string;
  recipients: string[];
  resendApiKey?: string;
  now?: Date;
  send?: (input: { to: string; shareUrl: string; idempotencyKey: string }) => Promise<{ id: string }>;
};

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char] ?? char);
}

function normalizeRecipients(recipients: string[]): string[] {
  return [...new Set(recipients.map((value) => value.trim().toLowerCase()).filter((value) => EMAIL_RE.test(value)))].slice(0, MAX_RECIPIENTS);
}

async function sendWithResend(apiKey: string, to: string, shareUrl: string, idempotencyKey: string): Promise<{ id: string }> {
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json", "Idempotency-Key": idempotencyKey },
    body: JSON.stringify({
      from: "Rishi <share@fidexa.org>",
      to: [to],
      subject: "Join my Rishi reading session",
      html: `<p>You have been invited to a shared reading session in Rishi.</p><p><a href="${escapeHtml(shareUrl)}">Open the reading session</a></p>`,
      text: `Open the Rishi reading session: ${shareUrl}`,
    }),
  });
  if (!response.ok) throw new Error(`RESEND_${response.status}`);
  const body = await response.json() as { id?: string };
  if (!body.id) throw new Error("RESEND_INVALID_RESPONSE");
  return { id: body.id };
}

export async function sendSessionInviteEmails(options: SessionInviteEmailOptions): Promise<SessionInviteEmailResult> {
  const recipients = normalizeRecipients(options.recipients);
  const now = options.now ?? new Date();
  const results: SessionInviteEmailResult["results"] = [];
  let attempted = 0;
  let sent = 0;
  let failed = 0;

  for (const email of recipients) {
    const idempotencyKey = `${options.sessionId}:${email}`;
    const deliveryId = crypto.randomUUID();
    await options.db.insert(sessionInviteDeliveries).values({
      id: deliveryId,
      inviteId: options.inviteId,
      recipientEmail: email,
      status: "pending",
      idempotencyKey,
      createdAt: now,
      updatedAt: now,
    }).onConflictDoNothing().run();
    const delivery = await options.db.select().from(sessionInviteDeliveries)
      .where(and(eq(sessionInviteDeliveries.inviteId, options.inviteId), eq(sessionInviteDeliveries.recipientEmail, email))).get() as SessionInviteDelivery | undefined;
    if (delivery?.status === "sent") {
      results.push({ email, status: "already_sent" });
      continue;
    }
    attempted += 1;
    try {
      const provider = options.send ?? ((input) => sendWithResend(options.resendApiKey ?? "", input.to, input.shareUrl, input.idempotencyKey));
      const result = await provider({ to: email, shareUrl: options.shareUrl, idempotencyKey });
      await options.db.update(sessionInviteDeliveries).set({ status: "sent", providerMessageId: result.id, errorCode: null, sentAt: now, updatedAt: now }).where(eq(sessionInviteDeliveries.id, delivery?.id ?? deliveryId)).run();
      sent += 1;
      results.push({ email, status: "sent" });
    } catch (error) {
      const errorCode = error instanceof Error ? error.message.slice(0, 128) : "EMAIL_PROVIDER_FAILED";
      await options.db.update(sessionInviteDeliveries).set({ status: "failed", errorCode, updatedAt: now }).where(eq(sessionInviteDeliveries.id, delivery?.id ?? deliveryId)).run();
      failed += 1;
      results.push({ email, status: "failed", errorCode });
    }
  }
  return { attempted, sent, failed, results };
}
