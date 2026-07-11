export const HIGHLIGHT_COLORS = [
    { name: 'yellow', hex: '#FBBF24' },
    { name: 'green', hex: '#34D399' },
    { name: 'blue', hex: '#60A5FA' },
    { name: 'pink', hex: '#F472B6' }
];
/**
 * Sentinel `color` value for note-only highlights — rows that exist only
 * to anchor a note to a CFI range, with no colored SVG overlay. The DB
 * column is `NOT NULL`, so we use a string sentinel rather than null.
 */
export const NOTE_COLOR_NONE = 'none';
export function isNoteOnly(row) {
    return row.color === NOTE_COLOR_NONE;
}
export function getHighlightHex(color) {
    if (color === NOTE_COLOR_NONE)
        return 'transparent';
    return HIGHLIGHT_COLORS.find((c) => c.name === color)?.hex ?? '#FBBF24';
}
