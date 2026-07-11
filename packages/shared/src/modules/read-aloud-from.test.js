import { describe, it, expect } from 'vitest';
import { findSentenceStart, buildPartialFirst } from './read-aloud-from';
describe('findSentenceStart', () => {
    it('returns 0 when offset is 0', () => {
        expect(findSentenceStart('Hello world. Goodbye world.', 0)).toBe(0);
    });
    it('returns 0 when offset is in the first sentence', () => {
        expect(findSentenceStart('Hello world. Goodbye world.', 5)).toBe(0);
    });
    it('returns the start of the second sentence when offset is in it', () => {
        const text = 'Hello world. Goodbye world.';
        // "Goodbye" starts at index 13 (after "Hello world. ")
        expect(findSentenceStart(text, 15)).toBe(13);
    });
    it('returns the start of the sentence containing the offset (mid-sentence)', () => {
        const text = 'First sentence. Second sentence here. Third.';
        // Second sentence starts at index 16
        expect(findSentenceStart(text, 25)).toBe(16);
    });
    it('clamps offsets beyond text length', () => {
        const text = 'One. Two. Three.';
        // Last sentence "Three." starts at index 10
        expect(findSentenceStart(text, 999)).toBe(10);
    });
    it('handles single-sentence text', () => {
        expect(findSentenceStart('A single sentence with no terminator', 10)).toBe(0);
    });
    it('handles empty text', () => {
        expect(findSentenceStart('', 0)).toBe(0);
    });
});
describe('buildPartialFirst', () => {
    it('returns full paragraph text and bare paragraph key when sentenceStart is 0', () => {
        // When the selection starts within the first sentence the partial is the
        // whole paragraph. The cache key must equal the paragraph index used by
        // normal play/prefetch so previously-cached audio hits instead of
        // triggering a refetch (which manifests as the "stuck in loading" bug
        // when the user uses "Read aloud from here" on a paragraph they've
        // already played).
        const result = buildPartialFirst('cfi:1', 'Hello. World.', 0);
        expect(result.partialFirstText).toBe('Hello. World.');
        expect(result.partialFirstKey).toBe('cfi:1');
        expect(result.sentenceStartChar).toBe(0);
    });
    it('returns only the second sentence when offset is in it', () => {
        const text = 'Hello world. Goodbye world.';
        const result = buildPartialFirst('cfi:p1', text, 15);
        expect(result.partialFirstText).toBe('Goodbye world.');
        expect(result.partialFirstKey).toBe('cfi:p1#s=13');
        expect(result.sentenceStartChar).toBe(13);
    });
    it('returns full paragraph when selection is past the last sentence', () => {
        const text = 'Just one sentence.';
        const result = buildPartialFirst('cfi:p1', text, 999);
        expect(result.partialFirstText).toBe('Just one sentence.');
        expect(result.sentenceStartChar).toBe(0);
    });
    it('handles empty paragraph text', () => {
        const result = buildPartialFirst('cfi:p1', '', 0);
        expect(result.partialFirstText).toBe('');
        expect(result.partialFirstKey).toBe('cfi:p1');
    });
});
