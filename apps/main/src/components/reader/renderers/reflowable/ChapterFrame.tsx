// apps/main/src/components/reader/renderers/reflowable/ChapterFrame.tsx
import { useEffect, useRef } from 'react';
import { sanitizeBookHtml } from '@/utils/sanitize-html';

export interface ChapterFrameProps {
  html: string;
  themeStyles: string;
  resolveResource: (path: string) => Promise<Blob | null>;
}

export function ChapterFrame({ html, themeStyles, resolveResource }: ChapterFrameProps) {
  const hostRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const shadow = host.shadowRoot ?? host.attachShadow({ mode: 'open' });

    const styleEl = document.createElement('style');
    styleEl.textContent = themeStyles;

    const fragment = sanitizeBookHtml(html);

    while (shadow.firstChild) shadow.removeChild(shadow.firstChild);
    shadow.appendChild(styleEl);
    shadow.appendChild(fragment);

    const blobUrls: string[] = [];

    const imgs = Array.from(shadow.querySelectorAll('img')) as HTMLImageElement[];
    for (const img of imgs) {
      const src = img.getAttribute('src');
      if (!src || src.startsWith('blob:') || src.startsWith('data:') || /^https?:/.test(src)) continue;
      void resolveResource(src).then((blob) => {
        if (blob) {
          const url = URL.createObjectURL(blob);
          img.setAttribute('src', url);
          blobUrls.push(url);
        } else {
          img.removeAttribute('src');
        }
      });
    }

    return () => {
      for (const url of blobUrls) URL.revokeObjectURL(url);
    };
  }, [html, themeStyles, resolveResource]);

  return <div className="chapter-frame-host" ref={hostRef} style={{ height: '100%', width: '100%' }} />;
}
