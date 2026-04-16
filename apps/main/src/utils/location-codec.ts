// apps/main/src/utils/location-codec.ts
import type { Location } from '@/types/reader';

export type BookKind = 'epub' | 'mobi' | 'pdf' | 'djvu';

export function encodeLocation(loc: Location): string {
  return JSON.stringify(loc);
}

export function decodeLocation(raw: string, kind: BookKind): Location {
  if (raw && raw.startsWith('{')) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && (parsed.kind === 'reflowable' || parsed.kind === 'paged')) {
        return parsed as Location;
      }
    } catch {
      // fall through to legacy decode
    }
  }

  if (raw && raw.startsWith('epubcfi(')) {
    return { kind: 'reflowable', chapterId: '', cfi: raw };
  }

  const asNumber = Number(raw);
  if (Number.isFinite(asNumber) && asNumber >= 0) {
    if (kind === 'pdf' || kind === 'djvu') {
      const oneIndexed = Math.max(1, Math.floor(asNumber));
      return { kind: 'paged', pageIndex: oneIndexed - 1 };
    }
    if (kind === 'mobi') {
      return { kind: 'reflowable', chapterId: String(Math.floor(asNumber)) };
    }
  }

  return kind === 'pdf' || kind === 'djvu'
    ? { kind: 'paged', pageIndex: 0 }
    : { kind: 'reflowable', chapterId: '' };
}
