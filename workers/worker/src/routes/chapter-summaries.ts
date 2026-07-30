import { createOpenAI } from "@ai-sdk/openai"
import { generateText, Output, APICallError } from "ai"
import { Hono } from "hono"
import { z } from "zod"
import { requireAuth } from "../index"
import { requireAiDataConsent } from "../middleware/ai-data-consent"
import { meterFromContext } from "../billing/meter"

const UUID_LOWER_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MAX_CONTENT_CHARACTERS = 12_000

const BodySchema = z.object({
  operation: z.enum(["summarize", "merge"]),
  bookID: z
    .string()
    .regex(UUID_LOWER_RE, "bookID must be a lowercase uuid")
    .optional(),
  book_id: z
    .string()
    .regex(UUID_LOWER_RE, "book_id must be a lowercase uuid")
    .optional(),
  contentVersion: z.string().min(1).max(256).optional(),
  chapterID: z.string().min(1).max(128),
  chapterName: z.string().min(1).max(256),
  input: z.string().min(1).max(MAX_CONTENT_CHARACTERS).optional(),
  sectionSummaries: z
    .array(z.string().min(1).max(2_000))
    .min(1)
    .max(32)
    .optional(),
  prompt: z.string().min(1).max(2_000),
  store: z.literal(false),
}).superRefine((body, ctx) => {
  const hasInput = typeof body.input === "string"
  const hasSections = Array.isArray(body.sectionSummaries)
  if (body.operation === "summarize" && (!hasInput || hasSections)) {
    ctx.addIssue({ code: "custom", message: "summarize requires input only" })
  }
  if (body.operation === "merge" && (hasInput || !hasSections)) {
    ctx.addIssue({ code: "custom", message: "merge requires sectionSummaries only" })
  }
  const sectionCharacters = body.sectionSummaries?.reduce(
    (total, section) => total + section.length,
    0,
  ) ?? 0
  if (sectionCharacters > MAX_CONTENT_CHARACTERS) {
    ctx.addIssue({ code: "custom", message: "sectionSummaries exceed content limit" })
  }
  if (body.bookID && body.book_id && body.bookID !== body.book_id) {
    ctx.addIssue({ code: "custom", message: "bookID and book_id must match" })
  }
})

const SummaryOutput = z.object({
  id: z.string().min(1).max(128),
  name: z.string().min(1).max(256),
  summary: z.string().min(1).max(800),
})

export const chapterSummariesRoutes = new Hono<{
  Bindings: Env
  Variables: { userId: string }
}>()

chapterSummariesRoutes.post(
  "/",
  requireAuth,
  requireAiDataConsent,
  async (c) => {
    const raw = await c.req.json().catch(() => null)
    const parsed = BodySchema.safeParse(raw)
    if (!parsed.success) {
      return c.json({ error: "bad_request", detail: parsed.error.message }, 400)
    }

    const body = parsed.data
    const content = body.operation === "summarize"
      ? `Chapter content:\n${body.input}`
      : `Section summaries:\n${body.sectionSummaries!.join("\n")}`
    const prompt = [
      "Summarize the supplied book material deterministically.",
      "Return a concise, factual summary of no more than 800 characters.",
      "Do not invent events, citations, or chapter metadata.",
      `Chapter ID: ${body.chapterID}`,
      `Chapter name: ${body.chapterName}`,
      `Requested operation: ${body.operation}`,
      `Additional instruction: ${body.prompt}`,
      content,
    ].join("\n\n")

    try {
      const openai = createOpenAI({ apiKey: c.env.OPENAI_API_KEY })
      const { output, usage } = await generateText({
        model: openai.responses("gpt-5-nano"),
        prompt,
        output: Output.object({ schema: SummaryOutput }),
        providerOptions: { openai: { store: false } },
      })

      c.executionCtx.waitUntil(
        meterFromContext(c.env, c.get("userId"), {
          type: "chat",
          model: "gpt-5-nano",
          inputTokens: usage.inputTokens ?? 0,
          outputTokens: usage.outputTokens ?? 0,
        }),
      )

      return c.json({
        id: body.chapterID,
        name: body.chapterName,
        summary: output.summary,
      })
    } catch (error) {
      if (APICallError.isInstance(error)) {
        return c.json({ error: error.message }, (error.statusCode as 400) || 500)
      }
      return c.json({ error: "Internal server error" }, 500)
    }
  },
)
