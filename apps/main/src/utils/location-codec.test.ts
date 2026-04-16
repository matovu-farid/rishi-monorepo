// apps/main/src/utils/location-codec.test.ts
import { describe, it, expect } from 'vitest';
import { encodeLocation, decodeLocation } from './location-codec';
import type { Location } from '@/types/reader';

describe('encodeLocation', () => {
  it('round-trips a reflowable location', () => {
    const loc: Location = { kind: 'reflowable', chapterId: 'ch3', cfi: 'epubcfi(/6/4!/4/2)' };
    expect(decodeLocation(encodeLocation(loc), 'epub')).toEqual(loc);
  });

  it('round-trips a paged location', () => {
    const loc: Location = { kind: 'paged', pageIndex: 47 };
    expect(decodeLocation(encodeLocation(loc), 'pdf')).toEqual(loc);
  });
});

describe('decodeLocation legacy fallback', () => {
  it('decodes legacy numeric string for PDF as 0-indexed page', () => {
    expect(decodeLocation('5', 'pdf')).toEqual({ kind: 'paged', pageIndex: 4 });
  });

  it('decodes legacy numeric string for DJVU as 0-indexed page', () => {
    expect(decodeLocation('1', 'djvu')).toEqual({ kind: 'paged', pageIndex: 0 });
  });

  it('decodes legacy numeric string for MOBI as chapter index', () => {
    expect(decodeLocation('3', 'mobi')).toEqual({ kind: 'reflowable', chapterId: '3' });
  });

  it('decodes legacy CFI string for EPUB as reflowable with cfi', () => {
    const cfi = 'epubcfi(/6/4!/4/2)';
    expect(decodeLocation(cfi, 'epub')).toEqual({ kind: 'reflowable', chapterId: '', cfi });
  });

  it('returns sensible defaults for empty/invalid', () => {
    expect(decodeLocation('', 'pdf')).toEqual({ kind: 'paged', pageIndex: 0 });
    expect(decodeLocation('', 'epub')).toEqual({ kind: 'reflowable', chapterId: '' });
  });
});
