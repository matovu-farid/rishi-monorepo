/**
 * EpubPageTracker — zustand store for EPUB page state.
 *
 * Uses a locIndex→page lookup map to ensure the same content always
 * shows the same page number regardless of navigation direction.
 *
 * First visit to a locIndex: assigns page from counter (±1 sequential).
 * Repeat visit: returns the stored page from the map.
 *
 * This solves the epub.js asymmetry where backward navigation visits
 * more intermediate sections than forward, causing counter drift.
 *
 * Per-book state is auto-persisted via zustand persist middleware.
 * All page events are logged to the error-dump file for debugging.
 */

import { create } from "zustand";
import { persist } from "zustand/middleware";
import { dumpError } from "@/utils/errorDump";

export interface PageInfo {
  current: number;
  total: number;
}

interface BookPageData {
  rawLocCount: number;
  avgLocsPerPage: number;
  lastLocIndex: number;
  lastPage: number;
  lastCfi: string;
}

function dump(action: string, data: Record<string, unknown>) {
  dumpError({
    source: "EpubPageTracker",
    location: action,
    error: JSON.stringify(data),
    context: `page=${data.page ?? "?"}, locIndex=${data.locIndex ?? "?"}`,
  });
}

function calcTotal(rawLocCount: number, avgLocsPerPage: number): number {
  return Math.max(1, Math.round(rawLocCount / Math.max(1, avgLocsPerPage)));
}

interface PageTrackerState {
  // ── Reactive state ──
  current: number;
  total: number;
  ready: boolean;
  locationsReady: boolean;

  // ── Internal ──
  _rawLocCount: number;
  _avgLocsPerPage: number;
  _lastLocIndex: number;
  _lastCfi: string;
  _bookId: string;

  // ── locIndex → page lookup (ensures same content = same page) ──
  _locPageMap: Record<number, number>;

  // ── Persisted per-book cache ──
  _bookCache: Record<string, BookPageData>;

  // ── Actions ──
  initBook: (bookId: string) => void;
  build: (rawLocationsCount: number, avgLocsPerPage: number) => void;
  goToCfi: (cfi: string, locationFromCfi: (cfi: string) => number) => PageInfo;
  setLocationsReady: (ready: boolean) => void;
  reset: () => void;
}

export const usePageTracker = create<PageTrackerState>()(
  persist(
    (set, get) => ({
      current: 1,
      total: 0,
      ready: false,
      locationsReady: false,
      _rawLocCount: 0,
      _avgLocsPerPage: 1,
      _lastLocIndex: -1,
      _lastCfi: "",
      _bookId: "",
      _locPageMap: {},
      _bookCache: {},

      initBook: (bookId) => {
        const cached = get()._bookCache[bookId];
        if (cached) {
          const total = calcTotal(cached.rawLocCount, cached.avgLocsPerPage);
          dump("initBook:cached", { bookId, ...cached, total });
          const hasValidCfi = Boolean(cached.lastCfi);
          set({
            _bookId: bookId,
            _rawLocCount: cached.rawLocCount,
            _avgLocsPerPage: cached.avgLocsPerPage,
            _lastLocIndex: hasValidCfi ? cached.lastLocIndex : -1,
            _lastCfi: hasValidCfi ? cached.lastCfi : "",
            current: cached.lastPage,
            total,
            ready: true,
            _locPageMap: {},
          });
        } else {
          dump("initBook:fresh", { bookId });
          set({
            _bookId: bookId,
            current: 1,
            total: 0,
            ready: false,
            locationsReady: false,
            _rawLocCount: 0,
            _avgLocsPerPage: 1,
            _lastLocIndex: -1,
            _lastCfi: "",
            _locPageMap: {},
          });
        }
      },

      build: (rawLocationsCount, avgLocsPerPage) => {
        const rawLocCount = Math.max(1, rawLocationsCount);
        const alp = Math.max(1, avgLocsPerPage);
        const total = calcTotal(rawLocCount, alp);
        dump("build", { rawLocationsCount, avgLocsPerPage, totalPages: total });
        set({ _rawLocCount: rawLocCount, _avgLocsPerPage: alp, total, ready: true });
      },

      goToCfi: (cfi, locationFromCfi) => {
        const state = get();
        let locIndex: number;
        try {
          locIndex = locationFromCfi(cfi);
          if (typeof locIndex !== "number" || isNaN(locIndex) || locIndex < 0) {
            dump("goToCfi:invalid", { locIndex, cfi });
            return { current: state.current, total: state.total };
          }
        } catch {
          dump("goToCfi:error", { cfi });
          return { current: state.current, total: state.total };
        }

        // Skip exact duplicate CFI
        if (cfi === state._lastCfi) {
          return { current: state.current, total: state.total };
        }

        // Cover section (spine 0) — skip entirely to prevent asymmetric events
        if (cfi.startsWith('epubcfi(/6/2!/')) {
          dump("goToCfi:cover-skip", { locIndex, cfi, page: state.current });
          return { current: state.current, total: state.total };
        }

        const { _lastLocIndex, _avgLocsPerPage, total, _locPageMap } = state;

        // ── If this locIndex was seen before, reuse the stored page ──
        if (_locPageMap[locIndex] !== undefined) {
          const storedPage = _locPageMap[locIndex];
          dump("goToCfi:mapped", { locIndex, page: storedPage });
          set({ current: storedPage, _lastLocIndex: locIndex, _lastCfi: cfi });
          // Update book cache with latest position
          const bookId = state._bookId;
          if (bookId) {
            set((s) => ({
              _bookCache: {
                ...s._bookCache,
                [bookId]: {
                  rawLocCount: s._rawLocCount,
                  avgLocsPerPage: s._avgLocsPerPage,
                  lastLocIndex: locIndex,
                  lastPage: storedPage,
                  lastCfi: cfi,
                },
              },
            }));
          }
          return { current: storedPage, total };
        }

        // ── New locIndex: calculate page from counter or formula ──
        const delta = locIndex - _lastLocIndex;
        const absDelta = Math.abs(delta);
        const jumpThreshold = _avgLocsPerPage * 2;
        let newPage = state.current;

        if (_lastLocIndex < 0) {
          newPage = Math.max(1, Math.min(Math.round(locIndex / _avgLocsPerPage) + 1, total));
          dump("goToCfi:first", { locIndex, page: newPage, avgLocsPerPage: _avgLocsPerPage });
        } else if (absDelta > jumpThreshold) {
          newPage = Math.max(1, Math.min(Math.round(locIndex / _avgLocsPerPage) + 1, total));
          dump("goToCfi:jump", { locIndex, prevLocIndex: _lastLocIndex, delta, page: newPage });
        } else if (delta > 0) {
          newPage = Math.min(state.current + 1, total);
          dump("goToCfi:forward", { locIndex, prevLocIndex: _lastLocIndex, page: newPage });
        } else if (delta < 0) {
          newPage = Math.max(state.current - 1, 1);
          dump("goToCfi:backward", { locIndex, prevLocIndex: _lastLocIndex, page: newPage });
        } else if (delta === 0) {
          const cfiForward = cfi > state._lastCfi;
          if (cfiForward) {
            newPage = Math.min(state.current + 1, total);
            dump("goToCfi:forward-sameLoc", { locIndex, page: newPage, cfi });
          } else {
            newPage = Math.max(state.current - 1, 1);
            dump("goToCfi:backward-sameLoc", { locIndex, page: newPage, cfi });
          }
        }

        // Store in the lookup map and update state
        const bookId = state._bookId;
        set((s) => ({
          current: newPage,
          _lastLocIndex: locIndex,
          _lastCfi: cfi,
          _locPageMap: { ...s._locPageMap, [locIndex]: newPage },
          _bookCache: bookId
            ? {
                ...s._bookCache,
                [bookId]: {
                  rawLocCount: s._rawLocCount,
                  avgLocsPerPage: s._avgLocsPerPage,
                  lastLocIndex: locIndex,
                  lastPage: newPage,
                  lastCfi: cfi,
                },
              }
            : s._bookCache,
        }));
        return { current: newPage, total };
      },

      setLocationsReady: (ready) => set({ locationsReady: ready }),

      reset: () => {
        set({
          current: 1,
          total: 0,
          ready: false,
          locationsReady: false,
          _rawLocCount: 0,
          _avgLocsPerPage: 1,
          _lastLocIndex: -1,
          _lastCfi: "",
          _bookId: "",
          _locPageMap: {},
        });
      },
    }),
    {
      name: "epub-page-tracker",
      partialize: (state) => ({ _bookCache: state._bookCache }) as PageTrackerState,
      version: 2,
      migrate: (persisted, version) => {
        if (version === 1) {
          const state = persisted as { _bookCache?: Record<string, any> };
          if (state._bookCache) {
            for (const key of Object.keys(state._bookCache)) {
              state._bookCache[key].lastCfi = state._bookCache[key].lastCfi || "";
            }
          }
        }
        return persisted as PageTrackerState;
      },
    },
  ),
);
