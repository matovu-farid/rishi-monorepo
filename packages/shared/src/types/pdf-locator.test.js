import { describe, it, expect } from 'vitest';
import { encodePdfLocator, decodePdfLocator, encodePdfCfiRange, decodePdfCfiRange, isPdfCfiRange, PDF_CFI_PREFIX } from './pdf-locator';
const SAMPLE = {
    page: 3,
    rects: [
        { x: 72, y: 120, w: 300, h: 12 },
        { x: 72, y: 132, w: 280, h: 12 }
    ]
};
describe('encodePdfLocator / decodePdfLocator', () => {
    it('round-trips a valid locator', () => {
        const enc = encodePdfLocator(SAMPLE);
        expect(JSON.parse(enc)).toEqual(SAMPLE);
        expect(decodePdfLocator(enc)).toEqual(SAMPLE);
    });
    it('returns null for null / undefined / empty input', () => {
        expect(decodePdfLocator(null)).toBeNull();
        expect(decodePdfLocator(undefined)).toBeNull();
        expect(decodePdfLocator('')).toBeNull();
    });
    it('returns null for malformed JSON', () => {
        expect(decodePdfLocator('not json')).toBeNull();
        expect(decodePdfLocator('{broken')).toBeNull();
    });
    it('returns null when page is missing or wrong type', () => {
        expect(decodePdfLocator('{"rects":[]}')).toBeNull();
        expect(decodePdfLocator('{"page":"3","rects":[]}')).toBeNull();
    });
    it('returns null when rects is not an array', () => {
        expect(decodePdfLocator('{"page":1,"rects":null}')).toBeNull();
        expect(decodePdfLocator('{"page":1,"rects":{}}')).toBeNull();
    });
    it('returns null when a rect has a non-numeric field', () => {
        expect(decodePdfLocator('{"page":1,"rects":[{"x":1,"y":2,"w":3,"h":"4"}]}')).toBeNull();
    });
});
describe('encodePdfCfiRange / decodePdfCfiRange', () => {
    it('encodes with the pdf: prefix', () => {
        const cfi = encodePdfCfiRange(SAMPLE);
        expect(cfi.startsWith(PDF_CFI_PREFIX)).toBe(true);
        expect(decodePdfCfiRange(cfi)).toEqual(SAMPLE);
    });
    it('returns null when the prefix is missing (EPUB CFIs)', () => {
        // An epubcfi must not be misread as a PDF locator — the prefix is the
        // disambiguator that lets one storage table hold both formats.
        expect(decodePdfCfiRange('epubcfi(/6/4!/4/2/1:0)')).toBeNull();
    });
    it('returns null when the payload is malformed even with the prefix', () => {
        expect(decodePdfCfiRange('pdf:not-json')).toBeNull();
    });
    it('isPdfCfiRange correctly identifies prefixed entries', () => {
        expect(isPdfCfiRange('pdf:{"page":1,"rects":[]}')).toBe(true);
        expect(isPdfCfiRange('epubcfi(/6/4)')).toBe(false);
        expect(isPdfCfiRange('')).toBe(false);
    });
});
