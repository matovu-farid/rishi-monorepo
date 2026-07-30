// workers/worker/src/routes/voice-sessions.ts

import { Hono } from "hono";
import { z } from "zod";

import { requireAuth } from "../middleware";
import { requireAiDataConsent } from "../middleware/ai-data-consent";
import { rollAllowancePeriodsForward } from "../billing/allowance-period-rollover";
import { coerceLanguage, mintRealtimeClientSecret } from "../realtime/client-secrets";
import { voiceSessionErrorResponse } from "./voice-session-errors";
import { REALTIME_VOICE_MODEL } from "@rishi/shared/realtime/model";

/**
 * Control WebSocket for an in-progress voice session. See
 * `docs/superpowers/plans/2026-07-17-voice-control-websocket.md` for the
 * full design and
 * `docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`
 * ("Control WebSocket") for the product contract.
 *
 * The iOS client sets a normal `Authorization: Bearer <token>` header on
 * its WebSocket upgrade request (`URLSessionWebSocketTask` supports
 * arbitrary headers, unlike the browser `WebSocket` constructor), so
 * `requireAuth` covers this route exactly like every other authenticated
 * route in this worker — no subprotocol-smuggled credential needed.
 */
export const voiceSessionsRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

voiceSessionsRoutes.get(
  "/:id/control",
  requireAuth,
  requireAiDataConsent,
  async (c) => {
  if (c.req.header("upgrade")?.toLowerCase() !== "websocket") {
    return c.json({ error: "expected_websocket" }, 426);
  }

  const rishiSessionId = c.req.param("id");
  const userId = c.get("userId");
  const stub = c.env.USER_USAGE_LEDGER.getByName(userId);

  const snapshot = await stub.getSessionSnapshot(rishiSessionId);
  if (!snapshot) {
    return c.json({ error: "no_active_session" }, 404);
  }

  // Terminal sessions still upgrade: the DO's fetch() accepts the WebSocket
  // and sends a terminal `{ type: "snapshot", ... }` so reconnects can learn
  // the ended state. Only unknown sessions 404 above.
  //
  // The DO's own fetch() re-validates and performs the actual upgrade —
  // forward the raw request so the Upgrade/Connection headers survive.
  return stub.fetch(c.req.raw);
  },
);

// ---------- POST / (start a voice session + mint an OpenAI client secret) ----------

const CreateVoiceSessionBodySchema = z
  .object({
    language: z.string().optional(),
    bookId: z.string().optional(),
    currentPage: z.number().optional(),
    outline: z
      .object({
        title: z.string(),
        author: z.string().optional(),
        chapters: z.array(z.string()),
      })
      .optional(),
  })
  .partial();

/**
 * Starts a Rishi voice session. Per the pricing/trial-launch design doc's
 * "Latency and background-work contract": "session creation and
 * client-secret minting are synchronous and intentionally short." This
 * handler does exactly two blocking calls — the ledger RPC and the OpenAI
 * mint — and nothing else; the control WebSocket, call-ID registration,
 * interval ticking, and hangup all happen out-of-band afterwards, per the
 * spec's "Voice Chat flow".
 *
 * Body is the same optional book-context shape `/api/realtime/client_secrets`
 * accepts (see `workers/worker/src/realtime/client-secrets.ts`), so a voice
 * session started from an open book still gets a book-aware system prompt.
 * All fields are optional; a missing/unparseable body degrades to
 * `{ language: "en" }`, matching that existing route's behavior.
 */
voiceSessionsRoutes.post(
  "/",
  requireAuth,
  requireAiDataConsent,
  async (c) => {
  const startupStartedAt = performance.now();
  const emitPhase = (phase: string, phaseStartedAt: number): void => {
    // Keep telemetry best-effort: logging must never change the request's
    // behavior, and this payload intentionally contains no user/session IDs,
    // credentials, book text, or other request data.
    try {
      const now = performance.now();
      console.log(
        JSON.stringify({
          event: "voice_sessions.start.phase",
          phase,
          elapsedMs: Math.round(now - phaseStartedAt),
          totalElapsedMs: Math.round(now - startupStartedAt),
        }),
      );
    } catch {
      // Ignore telemetry failures.
    }
  };

  try {
    const userId = c.get("userId");
    const rawBody = await c.req.json().catch(() => ({}));
    const body = CreateVoiceSessionBodySchema.safeParse(rawBody).data ?? {};

    // Rehydrate the ledger DO mirror from D1 before allowance checks — same
    // contract as `/api/billing/me` so post-migration caps apply immediately.
    const allowanceStartedAt = performance.now();
    try {
      await rollAllowancePeriodsForward(c.env, userId);
    } finally {
      emitPhase("allowance_refresh", allowanceStartedAt);
    }

    const stub = c.env.USER_USAGE_LEDGER.getByName(userId);

    // Ledger admission and OpenAI key minting are independent after the
    // allowance mirror has been refreshed. Start them together so setup time
    // is bounded by the slower of the two remote calls instead of their sum.
    // The small source tags preserve the route's existing error mapping when
    // Promise.all rejects whichever operation fails first.
    const ledgerStartedAt = performance.now();
    const sessionPromise = stub.createVoiceSession().then(
      (session) => {
        emitPhase("ledger_admission", ledgerStartedAt);
        return session;
      },
      (error: unknown) => {
        emitPhase("ledger_admission", ledgerStartedAt);
        throw { source: "ledger", error };
      },
    );
    const mintStartedAt = performance.now();
    const mintPromise = mintRealtimeClientSecret(c.env.OPENAI_API_KEY, {
      language: coerceLanguage(body.language),
      bookId: body.bookId,
      currentPage: body.currentPage,
      outline: body.outline,
    }).then(
      (minted) => {
        emitPhase("openai_mint", mintStartedAt);
        return minted;
      },
      (error: unknown) => {
        emitPhase("openai_mint", mintStartedAt);
        throw { source: "openai", error };
      },
    );

    let session: { rishiSessionId: string; nonce: string; capIntervals: number } | undefined;
    let minted: Awaited<ReturnType<typeof mintRealtimeClientSecret>> | undefined;
    try {
      [session, minted] = await Promise.all([sessionPromise, mintPromise]);
    } catch (err) {
      const failure = err as { source?: string; error?: unknown };
      if (failure.source === "ledger") {
        return voiceSessionErrorResponse(c, failure.error);
      }

      const mintErr = failure.source === "openai" ? failure.error : err;
      // The ledger already committed this session as `pending_registration`
      // with its grace-period alarm armed
      // (2026-07-17-user-usage-ledger-voice-session.md's
      // REGISTRATION_GRACE_MS = 10_000ms). If the app can't retry and never
      // registers a call ID, that alarm reconciles the session as
      // `registration_timeout` on its own — there is nothing to roll back
      // here, and no compensating call into the ledger is needed.
      console.error(
        JSON.stringify({
          event: "voice_sessions.mint_failed",
          rishiSessionId: session?.rishiSessionId ?? null,
          message: mintErr instanceof Error ? mintErr.message : String(mintErr),
        }),
      );
      return c.json(
        { error: "Failed to mint OpenAI realtime client secret", code: "OPENAI_MINT_FAILED" },
        502,
      );
    }

    // Promise.all fulfills both values together on the success path. Keep this
    // guard explicit so a future refactor cannot accidentally return a partial
    // response if one operation is changed to resolve without a value.
    if (!session || !minted) {
      return c.json(
        { error: "Failed to initialize realtime voice session", code: "VOICE_SESSION_INIT_FAILED" },
        502,
      );
    }

    return c.json({
      rishiSessionId: session.rishiSessionId,
      nonce: session.nonce,
      clientSecret: minted.clientSecret,
      capIntervals: session.capIntervals,
      realtimeModel: REALTIME_VOICE_MODEL,
    });
  } finally {
    emitPhase("total", startupStartedAt);
  }
  },
);

// ---------- POST /end-active (force-close live session) ----------

/**
 * Ends whichever voice session the ledger considers live for this user.
 * Must be registered before `/:id/end` so `end-active` is not captured as an id.
 */
voiceSessionsRoutes.post("/end-active", requireAuth, requireAiDataConsent, async (c) => {
  const userId = c.get("userId");
  const stub = c.env.USER_USAGE_LEDGER.getByName(userId);
  try {
    const result = await stub.endActiveVoiceSession();
    return c.json(result);
  } catch (err) {
    return voiceSessionErrorResponse(c, err);
  }
});

// ---------- POST /:id/end (client hangup) ----------

/**
 * Ends a Rishi voice session from the client so intentional End does not
 * leave an active row burning intervals until inactivity timeout. Also
 * unblocks create after abandoned pending_registration orphans.
 */
// Lifecycle cleanup carries only the authenticated session identifier and is
// intentionally available after consent revocation so an already-created
// voice session can be closed promptly.
voiceSessionsRoutes.post("/:id/end", requireAuth, async (c) => {
  const userId = c.get("userId");
  const rishiSessionId = c.req.param("id");
  const stub = c.env.USER_USAGE_LEDGER.getByName(userId);
  try {
    await stub.endVoiceSession(rishiSessionId);
  } catch (err) {
    return voiceSessionErrorResponse(c, err);
  }
  return c.json({ ok: true });
});

// ---------- POST /:id/register-call (bind the OpenAI call ID to this session) ----------

const RegisterCallBodySchema = z.object({
  callId: z.string().min(1),
  nonce: z.string().min(1),
});

/**
 * Registers the OpenAI `call_id` the vendored Swift Realtime connector
 * captured from the `Location` header of its WebRTC call creation. Per the
 * no-card-credit-trial design doc's "Voice flow" step 7: "If the app fails
 * to register the OpenAI call ID promptly, it must close the just-opened
 * voice connection and show a retryable error." Every non-2xx response below
 * is exactly that signal — the iOS client must close its just-opened OpenAI
 * WebRTC connection on any of them and, per that same step, offer retry.
 */
voiceSessionsRoutes.post("/:id/register-call", requireAuth, requireAiDataConsent, async (c) => {
  const userId = c.get("userId");
  const rishiSessionId = c.req.param("id");

  const rawBody = await c.req.json().catch(() => null);
  const parsedBody = RegisterCallBodySchema.safeParse(rawBody);
  if (!parsedBody.success) {
    return c.json(
      { error: "callId and nonce are required non-empty strings", code: "INVALID_REGISTER_CALL_BODY" },
      400,
    );
  }

  const stub = c.env.USER_USAGE_LEDGER.getByName(userId);
  try {
    await stub.registerCallId(rishiSessionId, parsedBody.data.callId, parsedBody.data.nonce);
  } catch (err) {
    return voiceSessionErrorResponse(c, err);
  }

  return c.json({ ok: true });
});
