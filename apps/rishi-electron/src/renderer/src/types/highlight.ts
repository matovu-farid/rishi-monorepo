export const HIGHLIGHT_COLORS = [
  { name: 'yellow', hex: '#FBBF24' },
  { name: 'green', hex: '#34D399' },
  { name: 'blue', hex: '#60A5FA' },
  { name: 'pink', hex: '#F472B6' },
] as const;

export type HighlightColor = (typeof HIGHLIGHT_COLORS)[number]['name'];

export function getHighlightHex(color: HighlightColor): string {
  return HIGHLIGHT_COLORS.find((c) => c.name === color)?.hex ?? '#FBBF24';
}
