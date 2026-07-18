import { VoiceSessionError } from "./errors";

/** Bound OpenAI hangup so a hung provider call cannot stall the DO alarm forever. */
const HANGUP_TIMEOUT_MS = 10_000;

/**
 * Calls OpenAI's `POST /v1/realtime/calls/{call_id}/hangup`, the same
 * endpoint style already used for `/v1/realtime/client_secrets` in
 * `workers/worker/src/index.ts` (~934-1008), with the same `OPENAI_API_KEY`
 * env binding. Resolves on a 2xx response; throws `VoiceSessionError` with
 * code `"hangup_failed"` on any network error, abort/timeout, or non-2xx
 * response so bounded retry in `attemptHangup` can continue.
 */
export async function callOpenAiHangup(apiKey: string, callId: string): Promise<void> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), HANGUP_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(
      `https://api.openai.com/v1/realtime/calls/${encodeURIComponent(callId)}/hangup`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}` },
        signal: controller.signal,
      },
    );
  } catch (networkError) {
    const message =
      networkError instanceof Error && networkError.name === "AbortError"
        ? `OpenAI hangup timed out after ${HANGUP_TIMEOUT_MS}ms`
        : `network error calling OpenAI hangup: ${(networkError as Error).message}`;
    throw new VoiceSessionError("hangup_failed", message);
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new VoiceSessionError(
      "hangup_failed",
      `OpenAI hangup returned ${response.status}: ${body.slice(0, 500)}`,
    );
  }
}
