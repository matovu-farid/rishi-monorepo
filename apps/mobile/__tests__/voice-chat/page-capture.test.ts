/**
 * Page-capture tests. Mocks `react-native-view-shot.captureRef` and
 * asserts the wrapper returns a base64 data URL with the expected
 * shape.
 */
const mockCaptureRef = jest.fn()
jest.mock('react-native-view-shot', () => ({
  captureRef: mockCaptureRef,
}), { virtual: true })

import {
  captureCurrentPage,
  setActivePageCaptureRef,
  getActivePageCaptureRef,
} from '@/lib/voice-chat/page-capture'

describe('page-capture', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    setActivePageCaptureRef(null)
  })

  it('returns the tiny placeholder when no ref is registered', async () => {
    const result = await captureCurrentPage()
    expect(result.dataUrl).toMatch(/^data:image\/png;base64,/)
    expect(result.bytes).toBeGreaterThan(0)
    expect(mockCaptureRef).not.toHaveBeenCalled()
  })

  it('calls captureRef with low-detail jpg defaults when no opts passed', async () => {
    mockCaptureRef.mockResolvedValue('data:image/jpeg;base64,XXX')
    setActivePageCaptureRef({ current: 'fake-ref' })

    const result = await captureCurrentPage()

    expect(mockCaptureRef).toHaveBeenCalledWith(
      { current: 'fake-ref' },
      expect.objectContaining({
        result: 'data-uri',
        format: 'jpg',
        quality: 0.6,
        width: 512,
      })
    )
    expect(result.dataUrl).toBe('data:image/jpeg;base64,XXX')
  })

  it('uses high-detail png + quality=1 when detail="high"', async () => {
    mockCaptureRef.mockResolvedValue('data:image/png;base64,YYY')
    setActivePageCaptureRef({ current: 'fake-ref' })

    await captureCurrentPage({ detail: 'high' })

    expect(mockCaptureRef).toHaveBeenCalledWith(
      { current: 'fake-ref' },
      expect.objectContaining({
        result: 'data-uri',
        format: 'png',
        quality: 1,
      })
    )
    // High detail does NOT pass a width — RN captures at native size.
    const callArgs = mockCaptureRef.mock.calls[0]![1] as Record<string, unknown>
    expect(callArgs.width).toBeUndefined()
  })

  it('estimates bytes from the base64 payload length', async () => {
    // 4-char base64 → ~3 bytes payload.
    mockCaptureRef.mockResolvedValue('data:image/jpeg;base64,QUJDRA==')
    setActivePageCaptureRef({ current: 'r' })
    const result = await captureCurrentPage()
    // 8 chars after the comma → 8 * 3 / 4 = 6 bytes (including padding).
    expect(result.bytes).toBeGreaterThan(0)
    expect(result.bytes).toBeLessThan(10)
  })

  it('exposes the registered ref for diagnostic reads', () => {
    const r = { current: 'view' }
    setActivePageCaptureRef(r)
    expect(getActivePageCaptureRef()).toBe(r)
    setActivePageCaptureRef(null)
    expect(getActivePageCaptureRef()).toBeNull()
  })
})
