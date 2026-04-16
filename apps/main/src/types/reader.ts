// apps/main/src/types/reader.ts

export type BookContent = ReflowableContent | PagedContent;

export interface ReflowableContent {
  kind: 'reflowable';
  metadata: Metadata;
  chapters: Chapter[];
  resolveResource: (path: string) => Promise<Blob | null>;
}

export interface Chapter {
  id: string;
  index: number;
  title?: string;
  loadHtml: () => Promise<string>;
}

export interface PagedContent {
  kind: 'paged';
  metadata: Metadata;
  pageCount: number;
  renderPage: (pageIndex: number, viewport: Viewport) => Promise<RenderedPage>;
}

export interface Viewport {
  scale: number;
  rotation?: 0 | 90 | 180 | 270;
}

export interface RenderedPage {
  source:
    | { kind: 'canvas'; canvas: HTMLCanvasElement }
    | { kind: 'blob'; url: string };
  textItems: TextItem[];
  width: number;
  height: number;
}

export interface TextItem {
  text: string;
  bbox: { x: number; y: number; width: number; height: number };
}

export interface Metadata {
  title?: string;
  author?: string;
  publisher?: string;
  tableOfContents: TOCEntry[];
}

export interface TOCEntry {
  title: string;
  location: Location;
  children: TOCEntry[];
}

export type Location =
  | { kind: 'reflowable'; chapterId: string; cfi?: string }
  | { kind: 'paged'; pageIndex: number };

export interface Paragraph {
  id: string;
  text: string;
  location: Location;
}

export interface SelectionInfo {
  text: string;
  location: Location;
  rects: DOMRect[];
  serialized: SerializedSelection;
}

export type SerializedSelection =
  | { kind: 'reflowable'; chapterId: string; cfiRange: string }
  | { kind: 'paged'; pageIndex: number; quadPoints: number[] };

export interface AdapterState {
  content: BookContent | null;
  status: 'loading' | 'ready' | 'error';
  error?: Error;
}

export interface RendererHandle {
  next: () => void;
  prev: () => void;
  jumpTo: (loc: Location) => void;
  getCurrentLocation: () => Location;
  applyHighlights: (highlights: AppliedHighlight[]) => void;
}

export interface AppliedHighlight {
  id: string;
  serialized: SerializedSelection;
  color: string;
}
