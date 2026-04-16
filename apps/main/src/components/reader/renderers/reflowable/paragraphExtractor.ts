// apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.ts
import type { Paragraph } from '@/types/reader';

const BLOCK_SELECTOR = 'p, li, h1, h2, h3, h4, h5, h6, blockquote, dt, dd, figcaption';

export function extractVisibleParagraphs(root: ShadowRoot | HTMLElement, chapterId: string): Paragraph[] {
  const elements = Array.from(root.querySelectorAll(BLOCK_SELECTOR));
  const paragraphs: Paragraph[] = [];
  for (let i = 0; i < elements.length; i++) {
    const el = elements[i];
    const text = (el.textContent ?? '').trim();
    if (!text) continue;
    paragraphs.push({
      id: `${chapterId}::${i}`,
      text,
      location: { kind: 'reflowable', chapterId, cfi: `${chapterId}::${i}` },
    });
  }
  return paragraphs;
}
