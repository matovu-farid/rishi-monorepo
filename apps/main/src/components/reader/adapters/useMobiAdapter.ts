// apps/main/src/components/reader/adapters/useMobiAdapter.ts
import { useEffect, useState } from 'react';
import { getMobiChapterCount, getMobiChapter } from '@/generated';
import type { AdapterState, ReflowableContent, Chapter, TOCEntry } from '@/types/reader';

export function useMobiAdapter(filepath: string): AdapterState {
  const [state, setState] = useState<AdapterState>({ content: null, status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const count = await getMobiChapterCount({ path: filepath });
        if (cancelled) return;
        setState({ content: buildContent(filepath, count), status: 'ready' });
      } catch (error) {
        if (cancelled) return;
        setState({ content: null, status: 'error', error: error as Error });
      }
    })();
    return () => { cancelled = true; };
  }, [filepath]);

  return state;
}

function buildContent(filepath: string, count: number): ReflowableContent {
  const chapters: Chapter[] = Array.from({ length: count }, (_, index) => ({
    id: String(index),
    index,
    title: `Chapter ${index + 1}`,
    loadHtml: () => getMobiChapter({ path: filepath, chapterIndex: index }),
  }));

  const tableOfContents: TOCEntry[] = chapters.map((c) => ({
    title: c.title!,
    location: { kind: 'reflowable', chapterId: c.id },
    children: [],
  }));

  return {
    kind: 'reflowable',
    metadata: { tableOfContents },
    chapters,
    resolveResource: async () => null,
  };
}
