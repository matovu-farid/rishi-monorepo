/**
 * OpenAI Realtime voice chat integration.
 * Same as Tauri version - no Tauri dependencies (uses fetch directly).
 */
import type { RealtimeSession } from "@openai/agents/realtime";
import { getRealtimeClientSecret, getContextForQuery } from "@/lib/api";

// Session cleanup registry
export const sessionCleanupMap = new WeakMap<RealtimeSession, () => void>();

let cachedKey: { key: string; timestamp: number } | null = null;
const KEY_TTL = 9 * 60 * 1000; // 9 minutes

async function getApiKey(): Promise<string> {
  if (cachedKey && Date.now() - cachedKey.timestamp < KEY_TTL) {
    return cachedKey.key;
  }
  const key = await getRealtimeClientSecret();
  cachedKey = { key, timestamp: Date.now() };
  return key;
}

export function prefetchRealtimeKey(): void {
  void getApiKey().catch(() => {
    // Silent fail for prefetch - key will be fetched on demand
  });
}

export async function startRealtime(bookId: number): Promise<RealtimeSession> {
  const { RealtimeAgent, RealtimeSession: RTSession } = await import("@openai/agents/realtime");
  const { tool } = await import("@openai/agents");

  const apiKey = await getApiKey();

  const bookContextTool = tool({
    name: "bookContext",
    description: "Retrieve relevant passages from the current book to answer the user's question",
    parameters: {
      type: "object" as const,
      properties: {
        query: { type: "string", description: "The search query to find relevant book passages" },
      },
      required: ["query"] as const,
      additionalProperties: true as const,
    },
    strict: false,
    execute: async (input: unknown) => {
      const parsed = input as { query: string };
      const contexts = await getContextForQuery({ queryText: parsed.query, bookId, k: 5 });
      return contexts.join("\n\n---\n\n");
    },
  });

  const endConversationTool = tool({
    name: "endConversation",
    description: "End the current conversation when the user is done",
    parameters: {
      type: "object" as const,
      properties: {},
      required: [] as const,
      additionalProperties: true as const,
    },
    strict: false,
    execute: async () => {
      return "Conversation ended.";
    },
  });

  const agent = new RealtimeAgent({
    name: "Rishi Book Assistant",
    instructions: `You are a helpful educational assistant for the book the user is reading.
    Use the bookContext tool to retrieve relevant passages when answering questions.
    Be concise and accurate. If you can't find relevant information in the book, say so honestly.
    When citing, reference page numbers or sections.`,
    tools: [bookContextTool, endConversationTool],
  });

  const session = new RTSession(agent, { apiKey, transport: "websocket", model: "gpt-4o-realtime-preview" });
  await session.connect({ apiKey });

  return session;
}
