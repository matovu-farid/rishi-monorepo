import { Context, Data, Effect, Either, Layer } from "effect";
import { and, eq } from "drizzle-orm";
import { sessionInviteDeliveries, type SessionInviteDelivery } from "./db/schema";
import { SessionSharingDependencyFailure } from "./session-sharing-errors";
import { SessionSharingPersistence } from "./session-sharing-use-cases";
import { sessionInviteEmail } from "./email-templates/session-invite";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_RECIPIENTS = 20;

export type SessionInviteEmailResult = {
  attempted: number;
  sent: number;
  failed: number;
  results: Array<{ email: string; status: "sent" | "failed" | "already_sent"; errorCode?: string }>;
};

export class SessionInviteDeliveryFailure extends Data.TaggedError("SessionInviteDeliveryFailure")<{
  readonly errorCode: string;
}> {}

export class SessionInviteEmailDelivery extends Context.Tag("SessionInviteEmailDelivery")<
  SessionInviteEmailDelivery,
  {
    readonly send: (input: {
      readonly to: string;
      readonly shareUrl: string;
      readonly bookTitle?: string;
      readonly idempotencyKey: string;
    }) => Effect.Effect<{ id: string }, SessionInviteDeliveryFailure>;
  }
>() {}

type ProviderSend = (input: {
  to: string;
  shareUrl: string;
  bookTitle?: string;
  idempotencyKey: string;
}) => Promise<{ id: string }>;

async function sendWithResend(
  apiKey: string | undefined,
  input: Parameters<ProviderSend>[0],
): Promise<{ id: string }> {
  if (!apiKey) throw new SessionInviteDeliveryFailure({ errorCode: "RESEND_UNAVAILABLE" });
  const message = await sessionInviteEmail({ bookTitle: input.bookTitle, shareUrl: input.shareUrl });
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json", "Idempotency-Key": input.idempotencyKey },
    body: JSON.stringify({
      from: "Rishi <share@fidexa.org>",
      to: [input.to],
      subject: message.subject,
      html: message.html,
      text: message.text,
    }),
  });
  if (!response.ok) throw new SessionInviteDeliveryFailure({ errorCode: `RESEND_${response.status}` });
  const body = await response.json() as { id?: string };
  if (!body.id) throw new SessionInviteDeliveryFailure({ errorCode: "RESEND_INVALID_RESPONSE" });
  return { id: body.id };
}

export function makeSessionInviteEmailDeliveryLayer(
  apiKey?: string,
  provider: ProviderSend = (input) => sendWithResend(apiKey, input),
): Layer.Layer<SessionInviteEmailDelivery> {
  return Layer.succeed(SessionInviteEmailDelivery, {
    send: (input) => Effect.tryPromise({
      try: () => provider(input),
      catch: (cause) => cause instanceof SessionInviteDeliveryFailure
        ? cause
        : new SessionInviteDeliveryFailure({ errorCode: "RESEND_UNAVAILABLE" }),
    }),
  });
}

function normalizeRecipients(recipients: string[]): string[] {
  return [...new Set(recipients.map((value) => value.trim().toLowerCase()).filter((value) => EMAIL_RE.test(value)))].slice(0, MAX_RECIPIENTS);
}

export function sendSessionInviteEmails(options: {
  sessionId: string;
  inviteId: string;
  shareUrl: string;
  bookTitle?: string;
  recipients: string[];
  now?: Date;
}): Effect.Effect<SessionInviteEmailResult, SessionSharingDependencyFailure, SessionSharingPersistence | SessionInviteEmailDelivery> {
  return Effect.gen(function* () {
    let attempted = 0;
    let sent = 0;
    let failed = 0;
    const results: SessionInviteEmailResult["results"] = [];
    const recipients = normalizeRecipients(options.recipients);
    const now = options.now ?? new Date();
    const delivery = yield* SessionInviteEmailDelivery;

    for (const email of recipients) {
      const idempotencyKey = `${options.sessionId}:${email}`;
      const deliveryId = crypto.randomUUID();
      yield* SessionSharingPersistence.query("session.invitation.delivery.create", (db) => db.insert(sessionInviteDeliveries).values({
        id: deliveryId,
        inviteId: options.inviteId,
        recipientEmail: email,
        status: "pending",
        idempotencyKey,
        createdAt: now,
        updatedAt: now,
      }).onConflictDoNothing().run());
      const existing = yield* SessionSharingPersistence.query("session.invitation.delivery.find", (db) => db.select().from(sessionInviteDeliveries)
        .where(and(eq(sessionInviteDeliveries.inviteId, options.inviteId), eq(sessionInviteDeliveries.recipientEmail, email))).get());
      const record = existing as SessionInviteDelivery | undefined;
      if (record?.status === "sent") {
        results.push({ email, status: "already_sent" });
        continue;
      }

      attempted += 1;
      const outcome = yield* delivery.send({ to: email, shareUrl: options.shareUrl, bookTitle: options.bookTitle, idempotencyKey }).pipe(Effect.either);
      if (Either.isRight(outcome)) {
        yield* SessionSharingPersistence.query("session.invitation.delivery.mark_sent", (db) => db.update(sessionInviteDeliveries)
          .set({ status: "sent", providerMessageId: outcome.right.id, errorCode: null, sentAt: now, updatedAt: now })
          .where(eq(sessionInviteDeliveries.id, record?.id ?? deliveryId)).run());
        sent += 1;
        results.push({ email, status: "sent" });
      } else {
        const errorCode = outcome.left.errorCode;
        yield* SessionSharingPersistence.query("session.invitation.delivery.mark_failed", (db) => db.update(sessionInviteDeliveries)
          .set({ status: "failed", errorCode, updatedAt: now })
          .where(eq(sessionInviteDeliveries.id, record?.id ?? deliveryId)).run());
        failed += 1;
        results.push({ email, status: "failed", errorCode });
      }
    }
    return { attempted, sent, failed, results };
  });
}
