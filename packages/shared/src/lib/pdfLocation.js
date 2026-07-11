export function parsePdfLocation(loc) {
    if (!loc)
        return { page: 0, offset: 0 };
    const parts = loc.split(':');
    const page = Number.parseInt(parts[0] ?? '', 10);
    const offset = Number.parseInt(parts[1] ?? '', 10);
    return {
        page: Number.isFinite(page) && page > 0 ? page : 0,
        offset: Number.isFinite(offset) && offset > 0 ? offset : 0
    };
}
export function formatPdfLocation(loc) {
    const offset = Math.max(0, Math.round(loc.offset));
    return `${loc.page}:${offset}`;
}
