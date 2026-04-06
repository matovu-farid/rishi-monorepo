export interface Highlight {
  id: string;
  bookId: string;
  cfiRange: string;
  text: string;
  color: 'yellow' | 'green' | 'blue' | 'pink';
  note: string | null;
  chapter: string | null;
  createdAt: number;
  updatedAt: number;
}

export type HighlightColor = Highlight['color'];

export const HIGHLIGHT_COLORS: { name: HighlightColor; hex: string }[] = [
  { name: 'yellow', hex: '#FBBF24' },
  { name: 'green', hex: '#34D399' },
  { name: 'blue', hex: '#60A5FA' },
  { name: 'pink', hex: '#F472B6' },
];

export const HIGHLIGHT_OPACITY = 0.3;
