/**
 * Convert a string to a numeric ID using a simple hash.
 * Matches the Tauri stringToNumberID utility for consistent page-data IDs.
 *
 * Extracted from apps/rishi-electron/src/renderer/src/lib/utils.ts so
 * mobile + worker can produce identical chunk IDs (deterministic on input).
 */
export function stringToNumberID(str) {
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
        const char = str.charCodeAt(i);
        hash = ((hash << 5) - hash + char) | 0;
    }
    return Math.abs(hash);
}
