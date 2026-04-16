// apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.browser.test.ts
import { describe, it, expect } from 'vitest';
import { extractVisibleParagraphs } from './paragraphExtractor';
import { sanitizeBookHtml } from '@/utils/sanitize-html';

function setup(html: string): ShadowRoot {
  const host = document.createElement('div');
  host.style.width = '600px';
  host.style.height = '400px';
  document.body.appendChild(host);
  const root = host.attachShadow({ mode: 'open' });
  root.appendChild(sanitizeBookHtml(html));
  return root;
}

describe('extractVisibleParagraphs', () => {
  it('extracts block-level text elements', () => {
    const root = setup('<p>one</p><p>two</p><h2>three</h2>');
    const result = extractVisibleParagraphs(root, 'chapter-id');
    expect(result.length).toBe(3);
    expect(result.map((p) => p.text)).toEqual(['one', 'two', 'three']);
    expect(result[0].location.kind).toBe('reflowable');
  });

  it('ignores empty elements', () => {
    const root = setup('<p>one</p><p>   </p><p>two</p>');
    const result = extractVisibleParagraphs(root, 'c');
    expect(result.map((p) => p.text)).toEqual(['one', 'two']);
  });

  it('produces stable ids based on chapter and DOM position', () => {
    const root = setup('<p>x</p><p>y</p>');
    const a = extractVisibleParagraphs(root, 'c1');
    const b = extractVisibleParagraphs(root, 'c1');
    expect(a.map((p) => p.id)).toEqual(b.map((p) => p.id));
  });
});
