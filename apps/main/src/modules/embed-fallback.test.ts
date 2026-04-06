import { describe, it, expect, vi, beforeEach } from 'vitest';

const { mockEmbed, mockStoreGet, mockLoad } = vi.hoisted(() => {
  const mockEmbed = vi.fn();
  const mockStoreGet = vi.fn();
  const mockLoad = vi.fn();
  return { mockEmbed, mockStoreGet, mockLoad };
});

vi.mock('@/generated/commands', () => ({
  embed: mockEmbed,
}));

vi.mock('@tauri-apps/plugin-store', () => ({
  load: mockLoad,
}));

import { embedWithFallback } from './embed-fallback';
import type { EmbedParam, EmbedResult } from '@/generated/types';

describe('embedWithFallback', () => {
  const sampleParams: EmbedParam[] = [
    { text: 'hello world', metadata: { id: 1, pageNumber: 1, bookId: 10 } },
    { text: 'foo bar', metadata: { id: 2, pageNumber: 2, bookId: 10 } },
  ];

  const onDeviceResults: EmbedResult[] = [
    { dim: 384, embedding: [0.1, 0.2], text: 'hello world', metadata: { id: 1, pageNumber: 1, bookId: 10 } },
    { dim: 384, embedding: [0.3, 0.4], text: 'foo bar', metadata: { id: 2, pageNumber: 2, bookId: 10 } },
  ];

  beforeEach(() => {
    vi.clearAllMocks();
    mockLoad.mockResolvedValue({ get: mockStoreGet });
    mockStoreGet.mockResolvedValue('test-token');
  });

  it('returns on-device results when embed() succeeds', async () => {
    mockEmbed.mockResolvedValue(onDeviceResults);

    const result = await embedWithFallback(sampleParams);

    expect(result).toEqual(onDeviceResults);
    expect(mockEmbed).toHaveBeenCalledWith({ embedparams: sampleParams });
  });

  it('calls server /api/embed when embed() throws and maps response', async () => {
    mockEmbed.mockRejectedValue(new Error('on-device failed'));

    const serverEmbeddings = [[0.5, 0.6, 0.7], [0.8, 0.9, 1.0]];
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ embeddings: serverEmbeddings }),
    });
    vi.stubGlobal('fetch', mockFetch);

    const result = await embedWithFallback(sampleParams);

    expect(mockFetch).toHaveBeenCalledWith(
      expect.stringContaining('/api/embed'),
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          'Authorization': 'Bearer test-token',
          'Content-Type': 'application/json',
        }),
      }),
    );

    expect(result).toHaveLength(2);
    expect(result[0].dim).toBe(3);
    expect(result[0].embedding).toEqual([0.5, 0.6, 0.7]);
    expect(result[0].text).toBe('hello world');
    expect(result[0].metadata).toEqual({ id: 1, pageNumber: 1, bookId: 10 });
    expect(result[1].dim).toBe(3);
    expect(result[1].embedding).toEqual([0.8, 0.9, 1.0]);

    vi.unstubAllGlobals();
  });

  it('throws if server fallback also fails', async () => {
    mockEmbed.mockRejectedValue(new Error('on-device failed'));

    const mockFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
    });
    vi.stubGlobal('fetch', mockFetch);

    await expect(embedWithFallback(sampleParams)).rejects.toThrow('Server embed failed: 500');

    vi.unstubAllGlobals();
  });
});
