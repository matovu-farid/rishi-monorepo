/**
 * Tests for the guardrail classification module.
 * Covers: relevant content, small talk, off-topic detection, fail-open, correct prompt.
 */

// ── Mock @/lib/api ──────────────────────────────────────────────────────────
const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({
  apiClient: mockApiClient,
}))

// ── Import after mocks ─────────────────────────────────────────────────────
import { checkGuardrail } from '@/lib/realtime/guardrails'

describe('guardrails', () => {
  beforeEach(() => {
    jest.clearAllMocks()
  })

  // Test 1: returns false (no tripwire) when content is relevant to book
  it('returns false when output is relevant to book', async () => {
    mockApiClient.mockResolvedValue({
      ok: true,
      text: async () =>
        JSON.stringify({ isRelevantToBook: true, isSmallTalk: false }),
    })

    const result = await checkGuardrail('The protagonist faces a moral dilemma in chapter 3.')
    expect(result).toBe(false)
  })

  // Test 2: returns false when content is small talk
  it('returns false when output is small talk', async () => {
    mockApiClient.mockResolvedValue({
      ok: true,
      text: async () =>
        JSON.stringify({ isRelevantToBook: false, isSmallTalk: true }),
    })

    const result = await checkGuardrail("You're welcome! Happy to help.")
    expect(result).toBe(false)
  })

  // Test 3: returns true (tripwire) when content is off-topic
  it('returns true when output is off-topic', async () => {
    mockApiClient.mockResolvedValue({
      ok: true,
      text: async () =>
        JSON.stringify({ isRelevantToBook: false, isSmallTalk: false }),
    })

    const result = await checkGuardrail('Here is how to make a bomb...')
    expect(result).toBe(true)
  })

  // Test 4: returns false (fail-open) when API call fails
  it('returns false when API call fails (fail-open)', async () => {
    mockApiClient.mockRejectedValue(new Error('Network error'))

    const result = await checkGuardrail('Some text')
    expect(result).toBe(false)
  })

  // Test 5: sends correct system prompt and agent output to Worker
  it('sends correct system prompt and agent output to completions endpoint', async () => {
    mockApiClient.mockResolvedValue({
      ok: true,
      text: async () =>
        JSON.stringify({ isRelevantToBook: true, isSmallTalk: false }),
    })

    await checkGuardrail('The book discusses philosophy.')

    expect(mockApiClient).toHaveBeenCalledWith(
      '/api/text/completions',
      expect.objectContaining({
        method: 'POST',
      })
    )

    const callArgs = mockApiClient.mock.calls[0]
    const body = JSON.parse(callArgs[1].body)

    // Verify system prompt is present
    expect(body.input[0].role).toBe('system')
    expect(body.input[0].content).toContain('Analyze the agent\'s output')
    expect(body.input[0].content).toContain('isRelevantToBook')
    expect(body.input[0].content).toContain('isSmallTalk')

    // Verify agent output is sent as user message
    expect(body.input[1].role).toBe('user')
    expect(body.input[1].content).toBe('The book discusses philosophy.')
  })
})
