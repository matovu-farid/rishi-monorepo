import { describe, it, expect, vi, beforeEach } from 'vitest';

// Use vi.hoisted so mock fns are available when vi.mock factory runs
const {
  mockExecute,
  mockWhere,
  mockSelectAll,
  mockSelectFrom,
  mockSet,
  mockUpdateTable,
  mockInsertInto,
} = vi.hoisted(() => {
  const mockExecute = vi.fn();
  const mockExecuteTakeFirst = vi.fn();
  const mockWhere: any = vi.fn((): any => ({
    where: mockWhere,
    execute: mockExecute,
    executeTakeFirst: mockExecuteTakeFirst,
  }));
  const mockSelectAll = vi.fn(() => ({ where: mockWhere }));
  const mockSelect = vi.fn(() => ({ where: mockWhere }));
  const mockSelectFrom = vi.fn(() => ({
    selectAll: mockSelectAll,
    select: mockSelect,
  }));
  const mockSet = vi.fn(() => ({ where: mockWhere }));
  const mockUpdateTable = vi.fn(() => ({ set: mockSet }));
  const mockValues = vi.fn(() => ({ execute: mockExecute }));
  const mockInsertInto = vi.fn(() => ({ values: mockValues }));

  return {
    mockExecute,
    mockExecuteTakeFirst,
    mockWhere,
    mockSelectAll,
    mockSelect,
    mockSelectFrom,
    mockSet,
    mockUpdateTable,
    mockValues,
    mockInsertInto,
  };
});

vi.mock('./kysley', () => ({
  db: {
    selectFrom: mockSelectFrom,
    updateTable: mockUpdateTable,
    insertInto: mockInsertInto,
  },
}));

import {
  updateHighlightNote,
  updateHighlightColor,
  deleteHighlightById,
  getHighlightsForBook,
} from './highlight-storage';

import { HIGHLIGHT_COLORS, getHighlightHex } from '@/types/highlight';

describe('HIGHLIGHT_COLORS', () => {
  it('has exactly 4 entries', () => {
    expect(HIGHLIGHT_COLORS).toHaveLength(4);
  });

  it('has correct names: yellow, green, blue, pink', () => {
    const names = HIGHLIGHT_COLORS.map((c) => c.name);
    expect(names).toEqual(['yellow', 'green', 'blue', 'pink']);
  });

  it('has correct hex values', () => {
    const hexes = HIGHLIGHT_COLORS.map((c) => c.hex);
    expect(hexes).toEqual(['#FBBF24', '#34D399', '#60A5FA', '#F472B6']);
  });

  it('getHighlightHex returns correct hex for each color', () => {
    expect(getHighlightHex('yellow')).toBe('#FBBF24');
    expect(getHighlightHex('green')).toBe('#34D399');
    expect(getHighlightHex('blue')).toBe('#60A5FA');
    expect(getHighlightHex('pink')).toBe('#F472B6');
  });
});

describe('highlight-storage extensions', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockExecute.mockResolvedValue(undefined);
  });

  describe('updateHighlightNote', () => {
    it('calls db.updateTable("highlights").set with note, updated_at, is_dirty:1', async () => {
      await updateHighlightNote('h-123', 'my note');

      expect(mockUpdateTable).toHaveBeenCalledWith('highlights');
      expect(mockSet).toHaveBeenCalledWith(
        expect.objectContaining({
          note: 'my note',
          is_dirty: 1,
        }),
      );
      expect(mockWhere).toHaveBeenCalledWith('id', '=', 'h-123');
      expect(mockExecute).toHaveBeenCalled();
    });
  });

  describe('updateHighlightColor', () => {
    it('calls db.updateTable("highlights").set with color, updated_at, is_dirty:1', async () => {
      await updateHighlightColor('h-456', 'blue');

      expect(mockUpdateTable).toHaveBeenCalledWith('highlights');
      expect(mockSet).toHaveBeenCalledWith(
        expect.objectContaining({
          color: 'blue',
          is_dirty: 1,
        }),
      );
      expect(mockWhere).toHaveBeenCalledWith('id', '=', 'h-456');
      expect(mockExecute).toHaveBeenCalled();
    });
  });

  describe('deleteHighlightById', () => {
    it('sets is_deleted=1, is_dirty=1 by id', async () => {
      await deleteHighlightById('h-789');

      expect(mockUpdateTable).toHaveBeenCalledWith('highlights');
      expect(mockSet).toHaveBeenCalledWith(
        expect.objectContaining({
          is_deleted: 1,
          is_dirty: 1,
        }),
      );
      expect(mockWhere).toHaveBeenCalledWith('id', '=', 'h-789');
      expect(mockExecute).toHaveBeenCalled();
    });
  });

  describe('getHighlightsForBook', () => {
    it('returns only non-deleted highlights', async () => {
      const mockRows = [{ id: 'h1', text: 'hello', is_deleted: 0 }];
      mockExecute.mockResolvedValueOnce(mockRows);

      const result = await getHighlightsForBook('book-abc');

      expect(mockSelectFrom).toHaveBeenCalledWith('highlights');
      expect(mockSelectAll).toHaveBeenCalled();
      expect(mockWhere).toHaveBeenCalledWith('book_id', '=', 'book-abc');
      expect(mockWhere).toHaveBeenCalledWith('is_deleted', '=', 0);
      expect(result).toEqual(mockRows);
    });
  });
});
