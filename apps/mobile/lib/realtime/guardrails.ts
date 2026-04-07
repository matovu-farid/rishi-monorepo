import { apiClient } from '@/lib/api'

const GUARDRAIL_SYSTEM_PROMPT = `Analyze the agent's output and classify it into one of three categories:
1. Relevant to the book: The output is answering questions, explaining concepts, or discussing content related to the book the user is reading.
2. Small talk: The output is engaging in friendly conversation, greetings, acknowledgments, pleasantries, or casual responses that are part of natural conversation flow.
3. Off-topic: The output is discussing something completely unrelated to the book AND is not small talk.

Respond with JSON: { "isRelevantToBook": boolean, "isSmallTalk": boolean }`

/**
 * Classify AI output via Worker LLM completions endpoint.
 * Returns true if tripwire triggered (output is off-topic), false otherwise.
 * Fails open (returns false) on any error to avoid blocking realtime audio.
 */
export async function checkGuardrail(agentOutput: string): Promise<boolean> {
  try {
    const response = await apiClient('/api/text/completions', {
      method: 'POST',
      body: JSON.stringify({
        input: [
          { role: 'system', content: GUARDRAIL_SYSTEM_PROMPT },
          { role: 'user', content: agentOutput },
        ],
      }),
    })

    if (!response.ok) return false

    const text = await response.json() as string
    // Parse the LLM response -- may be wrapped in markdown code fences
    const jsonMatch = text.match(/\{[\s\S]*\}/)
    if (!jsonMatch) return false

    const result = JSON.parse(jsonMatch[0])
    // Tripwire fires only when output is NEITHER relevant to book NOR small talk
    return !(result.isRelevantToBook ?? false) && !(result.isSmallTalk ?? false)
  } catch (error) {
    console.warn('[guardrails] Classification failed, failing open:', error)
    return false
  }
}
