// v1 — no RAG; v1.1 deferred work: book_id is only a system-message hint, not a retrieval signal.
//
// POST /api/chat — streaming chat handler for the iOS RishiChat package.
//
// Mirrors the iOS ChatStreamEndpoint contract locked in
// apps/apple/Packages/RishiChat/Sources/RishiChat/Service/ChatStreamEndpoint.swift
// (POST /api/chat, body { book_id?, query }) and emits SSE frames that decode
// cleanly as ChatResponseChunk ({ delta?, tool_call?, done? }) per
// apps/apple/Packages/RishiChat/Sources/RishiChat/Models/ChatResponseChunk.swift.
//
// Pipeline:
//   1. requireAuth        — Better Auth session check (workers/worker/src/index.ts).
//   2. requireActiveSub   — billing gate; 402 BILLING_INACTIVE on block
//                           (workers/worker/src/billing/sub-gate.ts).
//   3. zod body parse     — 400 bad_request on schema fail (empty query, > 50000
//                           chars, non-uuid book_id).
//   4. streamText         — ai SDK against openai.responses("gpt-5-nano") with
//                           providerOptions.openai.store = false (mirrors the
//                           existing /api/text/completions pattern at
//                           workers/worker/src/index.ts:456).
//   5. SSE encoding        — handcrafted ReadableStream so the wire body uses
//                           snake_case { delta } and { done: true } frames —
//                           required because the iOS decoder is keyed by
//                           CodingKeys (delta, tool_call, done).
//   6. metering           — onFinish enqueues meterFromContext via
//                           c.executionCtx.waitUntil with type "chat" + model
//                           "gpt-5-nano" + SDK-reported usage.
//
// book_id is folded in as a system-message hint only:
//   "The user is currently reading a book with ID <uuid>. Use this as context
//    if relevant."
// No embeddings, no vector retrieval — RAG ships in v1.1.
import { Hono } from "hono";
import { z } from "zod";
import { createOpenAI } from "@ai-sdk/openai";
import { streamText } from "ai";
import { requireAuth } from "../index";
import { meterFromContext } from "../billing/meter";
// Lowercase canonical UUID. iOS encodes UUIDs lowercase
// (RishiChat/Models/ChatRequest.swift); enforce that on the wire so an
// uppercased iOS encoder bug surfaces as a 400 instead of silently mis-keying
// downstream RAG lookups in v1.1.
const UUID_LOWER_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const BodySchema = z.object({
    book_id: z
        .string()
        .regex(UUID_LOWER_RE, "book_id must be a lowercase uuid")
        .optional(),
    query: z
        .string()
        .min(1, "query must be a non-empty string")
        .max(50000, "query must be under 50000 characters"),
});
export const chatRoutes = new Hono();
chatRoutes.post("/", requireAuth, async (c) => {
    const raw = await c.req.json().catch(() => null);
    const parsed = BodySchema.safeParse(raw);
    if (!parsed.success) {
        return c.json({ error: "bad_request", detail: parsed.error.message }, 400);
    }
    const { book_id, query } = parsed.data;
    const messages = [];
    if (book_id) {
        messages.push({
            role: "system",
            content: `The user is currently reading a book with ID ${book_id}. Use this as context if relevant.`,
        });
    }
    messages.push({ role: "user", content: query });
    const openai = createOpenAI({ apiKey: c.env.OPENAI_API_KEY });
    const userId = c.get("userId");
    // streamText returns synchronously; .textStream is the AsyncIterable<string>
    // we drain into the SSE encoder below. providerOptions.openai.store = false
    // opts out of OpenAI request retention (mirrors /api/text/completions).
    const result = streamText({
        model: openai.responses("gpt-5-nano"),
        messages,
        providerOptions: { openai: { store: false } },
        onFinish: ({ usage, }) => {
            c.executionCtx.waitUntil(meterFromContext(c.env, userId, {
                type: "chat",
                model: "gpt-5-nano",
                inputTokens: usage?.inputTokens ?? 0,
                outputTokens: usage?.outputTokens ?? 0,
            }));
        },
    });
    // Build the SSE stream ourselves so each frame body is single-line JSON
    // matching iOS ChatResponseChunk snake_case keys exactly.
    const encoder = new TextEncoder();
    const sseStream = new ReadableStream({
        async start(controller) {
            try {
                for await (const delta of result.textStream) {
                    if (typeof delta !== "string" || delta.length === 0)
                        continue;
                    const frame = `data: ${JSON.stringify({ delta })}\n\n`;
                    controller.enqueue(encoder.encode(frame));
                }
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ done: true })}\n\n`));
            }
            catch (e) {
                const msg = e instanceof Error ? e.message : "stream_error";
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ done: true, error: msg })}\n\n`));
            }
            finally {
                controller.close();
            }
        },
    });
    return new Response(sseStream, {
        status: 200,
        headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            Connection: "keep-alive",
        },
    });
});
