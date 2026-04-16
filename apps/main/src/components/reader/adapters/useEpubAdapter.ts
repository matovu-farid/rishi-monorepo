// apps/main/src/components/reader/adapters/useEpubAdapter.ts
import { useEffect, useRef, useState } from 'react';
import ePub, { Book } from 'epubjs';
import type { NavItem } from 'epubjs/types/navigation';
import type { SpineItem } from 'epubjs/types/section';
import type { AdapterState, ReflowableContent, TOCEntry, Chapter } from '@/types/reader';

export function useEpubAdapter(filepath: string): AdapterState {
  const [state, setState] = useState<AdapterState>({ content: null, status: 'loading' });
  // Reset to loading whenever filepath changes
  const prevFilepath = useRef<string | undefined>(undefined);
  if (prevFilepath.current !== filepath) {
    prevFilepath.current = filepath;
    // Reset state synchronously on filepath change (during render)
    if (state.status !== 'loading') {
      setState({ content: null, status: 'loading' });
    }
  }

  useEffect(() => {
    let cancelled = false;
    let book: Book | undefined;

    void (async () => {
      try {
        // NOTE: We fetch the epub as an ArrayBuffer before passing it to epubjs.
        // This avoids the URL-resolution issues that arise when epubjs opens a
        // URL-based archived EPUB: the spine section URLs get resolved to full HTTP
        // URLs that don't match the archive's internal paths (archive.getText uses
        // url.substr(1) expecting a leading-slash archive path like '/EPUB/page.xhtml').
        // Passing an ArrayBuffer keeps all section.url values as relative archive paths,
        // so section.render() / the default Request utility can look them up correctly.
        const response = await fetch(filepath);
        if (!response.ok) {
          throw new Error(`Failed to fetch EPUB: ${response.status} ${response.statusText}`);
        }
        const buffer = await response.arrayBuffer();
        if (cancelled) return;

        book = ePub(buffer as unknown as string);

        // NOTE: epubjs Book constructor catches open() failures and emits 'openFailed'
        // instead of rejecting book.ready. We must listen for this event to surface errors.
        const onOpenFailed = (err: Error) => {
          if (cancelled) return;
          setState({ content: null, status: 'error', error: err instanceof Error ? err : new Error(String(err)) });
        };
        book.on('openFailed', onOpenFailed);

        await book.ready;
        if (cancelled) return;

        book.off('openFailed', onOpenFailed);
        const content = buildContent(book);
        setState({ content, status: 'ready' });
      } catch (error) {
        if (cancelled) return;
        setState({ content: null, status: 'error', error: error as Error });
      }
    })();

    return () => {
      cancelled = true;
      if (book) {
        // NOTE: Cleanup wrapped in try/catch because book.destroy() may throw if
        // called twice (e.g. in React StrictMode double-invoke).
        try { book.destroy(); } catch { /* already destroyed */ }
      }
    };
  }, [filepath]);

  return state;
}

function buildContent(book: Book): ReflowableContent {
  // SpineItem type doesn't declare `idref`, but the epubjs spine parser sets it
  // at runtime. Augment for type-safe access without cast-noise at call sites.
  type RuntimeSpineItem = SpineItem & { idref: string };

  // NOTE: PackagingMetadataObject has all fields typed as non-optional strings,
  // but at runtime fields may be undefined (missing from OPF). Cast to loose type.
  const meta = book.packaging.metadata as unknown as Record<string, string | undefined>;

  // NOTE: book.spine.spineItems is the runtime array property (confirmed in spine.js source).
  // The TypeScript Spine type does not declare it; cast to access it.
  const spineItems = (book.spine as unknown as { spineItems: RuntimeSpineItem[] }).spineItems;

  // NOTE: Filter out spine items that have no URL — these are spine entries referencing
  // manifest items that don't exist (e.g. a <itemref idref="cover"/> with no matching
  // manifest <item id="cover">). Such items cannot be loaded and must be skipped.
  const validItems = spineItems.filter((item) => item.url != null);

  const chapters: Chapter[] = validItems.map((item, index) => ({
    id: item.idref,
    index,
    // book.navigation.get() takes an href; SpineItem.href may be undefined, guard it.
    title: item.href
      ? book.navigation?.get(item.href)?.label?.trim() || undefined
      : undefined,
    loadHtml: async () => {
      // NOTE: Using item.index (numeric) for spine lookup — the most reliable method.
      // book.spine.get(idref) requires a '#' prefix to look up by id, which is error-prone.
      const section = book.spine.get(item.index);
      if (!section) throw new Error(`Spine item ${item.idref} (index ${item.index}) not found`);
      // NOTE: We pass book.load.bind(book) as the request function. This ensures
      // that for archived (ArrayBuffer) EPUBs, the archive's getText() is used to
      // load section content instead of an HTTP fetch of the relative path.
      // section.render() serialises the loaded Document to a string in one step.
      // section.render() runtime returns a Promise<string>, but the bundled type is loose.
      const rendered = await (section.render(book.load.bind(book)) as unknown as Promise<string | Node>);
      if (typeof rendered === 'string') return rendered;
      // Defensive fallback: normalise unexpected Node return to string
      return new XMLSerializer().serializeToString(rendered as unknown as Node);
    },
  }));

  return {
    kind: 'reflowable',
    metadata: {
      title: meta.title,
      author: meta.creator,
      publisher: meta.publisher,
      tableOfContents: book.navigation
        ? convertToc(book.navigation.toc, chapters)
        : [],
    },
    chapters,
    resolveResource: async (path) => {
      // NOTE: book.archive may be undefined if the EPUB was not opened from a ZIP.
      // Fall back to null on any failure instead of throwing.
      try {
        const blob = await book.archive.getBlob(path);
        return blob ?? null;
      } catch {
        return null;
      }
    },
  };
}

function convertToc(
  items: NavItem[],
  chapters: Chapter[],
): TOCEntry[] {
  return items.map((item) => {
    // NOTE: TOC href format varies (may include fragment like "chapter01.xhtml#section1").
    // Use fuzzy includes match against spine item id (idref) to find the chapter.
    const chapterId = chapters.find((c) => item.href.includes(c.id))?.id ?? '';
    return {
      title: item.label.trim(),
      location: { kind: 'reflowable' as const, chapterId },
      children: item.subitems ? convertToc(item.subitems, chapters) : [],
    };
  });
}
