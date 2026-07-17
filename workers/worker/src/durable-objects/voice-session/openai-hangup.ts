import { VoiceSessionError } from "./errors";

/**
 * Calls OpenAI's `POST /v1/realtime/calls/{call_id}/hangup`, the same
 * endpoint style already used for `/v1/realtime/client_secrets` in
 * `workers/worker/src/index.ts` (~934-1008), with the same `OPENAI_API_KEY`
 * env binding. Resolves on a 2xx response; throws `VoiceSessionError` with
 * code `"hangup_failed"` on any network error or non-2xx response.
 */
export async function callOpenAiHangup(apiKey: string, callId: string): Promise<void> {
  let response: Response;
  try {
    response = await fetch(
      `https://api.openai.com/v1/realtime/calls/${encodeURIComponent(callId)}/hangup`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}` },
      },
    );
  } catch (networkError) {
    throw new VoiceSessionError(
      "hangup_failed",
      `network error calling OpenAI hangup: ${(networkError as Error).message}`,
    );
  }
  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new VoiceSessionError(
      "hangup_failed",
      `OpenAI hangup returned ${response.status}: ${body.slice(0, 500)}`,
    );
  }
}
