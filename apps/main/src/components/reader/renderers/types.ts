// apps/main/src/components/reader/renderers/types.ts
import type {
  ReflowableContent, PagedContent, Location, Paragraph, SelectionInfo,
  Viewport, RendererHandle, AppliedHighlight,
} from '@/types/reader';

export type Theme = {
  bg: string;
  fg: string;
  accent: string;
};

export type FontSettings = {
  family: string;
  size: number; // px
  lineHeight: number; // unitless
};

export interface ReflowableRendererProps {
  content: ReflowableContent;
  location: Extract<Location, { kind: 'reflowable' }>;
  theme: Theme;
  fontSettings: FontSettings;
  highlights: AppliedHighlight[];
  onLocationChange:          (loc: Location) => void;
  onVisibleParagraphsChange: (paragraphs: Paragraph[]) => void;
  onSelection:               (selection: SelectionInfo | null) => void;
}

export interface PagedRendererProps {
  content: PagedContent;
  location: Extract<Location, { kind: 'paged' }>;
  theme: Theme;
  viewport: Viewport;
  invertedDarkMode: boolean;
  highlights: AppliedHighlight[];
  onLocationChange:          (loc: Location) => void;
  onVisibleParagraphsChange: (paragraphs: Paragraph[]) => void;
  onSelection:               (selection: SelectionInfo | null) => void;
}

export type { RendererHandle };
