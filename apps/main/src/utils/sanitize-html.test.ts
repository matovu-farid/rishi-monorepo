// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { sanitizeBookHtml } from './sanitize-html';

describe('sanitizeBookHtml', () => {
  it('strips <script> tags', () => {
    const out = sanitizeBookHtml('<p>hi</p><script>alert(1)</script>');
    const html = fragmentToString(out);
    expect(html).not.toContain('script');
    expect(html).toContain('hi');
  });

  it('strips inline event handlers', () => {
    const out = sanitizeBookHtml('<img src="x" onerror="alert(1)">');
    expect(fragmentToString(out)).not.toContain('onerror');
  });

  it('strips javascript: URLs in href', () => {
    const out = sanitizeBookHtml('<a href="javascript:alert(1)">click</a>');
    expect(fragmentToString(out)).not.toContain('javascript:');
  });

  it('strips <iframe>, <object>, <embed>', () => {
    const out = sanitizeBookHtml('<iframe src="x"></iframe><object></object><embed>');
    const html = fragmentToString(out);
    expect(html).not.toContain('iframe');
    expect(html).not.toContain('object');
    expect(html).not.toContain('embed');
  });

  it('strips SVG-based XSS', () => {
    const out = sanitizeBookHtml('<svg><script>alert(1)</script></svg>');
    expect(fragmentToString(out)).not.toContain('script');
  });

  it('preserves benign typography', () => {
    const html = '<p>Hello <em>world</em>.</p><blockquote>quoted</blockquote><ul><li>x</li></ul>';
    const out = fragmentToString(sanitizeBookHtml(html));
    expect(out).toContain('<em>world</em>');
    expect(out).toContain('<blockquote>quoted</blockquote>');
    expect(out).toContain('<li>x</li>');
  });

  it('preserves images with safe src attributes', () => {
    const out = fragmentToString(sanitizeBookHtml('<img src="blob:foo" alt="x">'));
    expect(out).toContain('<img');
    expect(out).toContain('src="blob:foo"');
    expect(out).toContain('alt="x"');
  });

  it('preserves internal anchors', () => {
    const out = fragmentToString(sanitizeBookHtml('<a href="#footnote-1">1</a>'));
    expect(out).toContain('href="#footnote-1"');
  });

  it('strips data:text/html URIs in src', () => {
    const out = fragmentToString(
      sanitizeBookHtml('<img src="data:text/html,<script>alert(1)</script>">')
    );
    expect(out).not.toContain('data:text/html');
  });

  it('strips data:image/svg+xml URIs in src', () => {
    const out = fragmentToString(
      sanitizeBookHtml('<img src="data:image/svg+xml,<svg onload=alert(1)>">')
    );
    expect(out).not.toContain('data:image/svg+xml');
  });

  it('strips data:text/javascript URIs in src', () => {
    const out = fragmentToString(
      sanitizeBookHtml('<img src="data:text/javascript,alert(1)">')
    );
    expect(out).not.toContain('data:text/javascript');
  });

  it('preserves data:image/png base64 URIs in src', () => {
    // 1x1 transparent PNG
    const png = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    const out = fragmentToString(sanitizeBookHtml(`<img src="${png}">`));
    expect(out).toContain('data:image/png;base64,');
  });
});

function fragmentToString(fragment: DocumentFragment): string {
  const div = document.createElement('div');
  div.appendChild(fragment);
  return div.outerHTML;
}
