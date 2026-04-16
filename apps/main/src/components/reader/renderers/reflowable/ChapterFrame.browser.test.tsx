// apps/main/src/components/reader/renderers/reflowable/ChapterFrame.browser.test.tsx
// NOTE: Deviations from plan spec:
// 1. File is .browser.test.tsx (not .test.tsx) — project convention for browser tests.
// 2. Uses vitest-browser-react render (async) — matches project pattern.
// 3. render() is awaited since vitest-browser-react render returns a Promise<RenderResult>.
import { describe, it, expect } from 'vitest';
import { render } from 'vitest-browser-react';
import { ChapterFrame } from './ChapterFrame';

describe('ChapterFrame', () => {
  it('mounts sanitized HTML inside shadow root', async () => {
    const html = '<p>hello</p><script>window.X=1</script>';
    const { container } = await render(
      <ChapterFrame
        html={html}
        themeStyles=":host{color:red}"
        resolveResource={async () => null}
      />,
    );
    const host = container.querySelector('.chapter-frame-host') as HTMLElement;
    expect(host).toBeTruthy();
    const shadow = host.shadowRoot!;
    expect(shadow).toBeTruthy();
    expect(shadow.querySelector('p')?.textContent).toBe('hello');
    expect(shadow.querySelector('script')).toBeNull();
    expect((window as never as { X?: number }).X).toBeUndefined();
  });

  it('rewrites internal img src via resolveResource', async () => {
    const blob = new Blob(['x'], { type: 'image/png' });
    const html = '<p><img src="images/foo.png" alt="f"></p>';
    const { container } = await render(
      <ChapterFrame
        html={html}
        themeStyles=""
        resolveResource={async (path: string) => (path === 'images/foo.png' ? blob : null)}
      />,
    );
    const host = container.querySelector('.chapter-frame-host') as HTMLElement;
    await new Promise((r) => setTimeout(r, 50)); // wait for async resolveResource
    const img = host.shadowRoot!.querySelector('img') as HTMLImageElement;
    expect(img.src).toMatch(/^blob:/);
  });
});
