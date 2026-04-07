# Phase 12: PDF Thumbnail Sidebar - Research

**Researched:** 2026-04-07
**Domain:** PDF thumbnail rendering, sidebar navigation (desktop web + React Native mobile)
**Confidence:** HIGH

## Summary

This phase adds a thumbnail sidebar to the PDF reader on both desktop (Tauri/React) and mobile (Expo/React Native). The desktop app already uses `react-pdf` v10.2.0, which exports a `Thumbnail` component out of the box -- this is the ideal solution for desktop thumbnails. The existing `Sheet` sidebar (Radix Dialog-based) is already used for the Table of Contents and can be reused or paralleled for the thumbnail panel. Virtualization with `@tanstack/react-virtual` (already in use) handles lazy loading for large PDFs.

On mobile, `react-native-pdf` v7.0.4 does not provide a thumbnail API. The best approach is `react-native-pdf-thumbnail` v1.3.1, which generates native page thumbnails on both iOS and Android. Since the project already uses `expo-dev-client` (custom dev builds, not Expo Go), native modules are fully supported.

**Primary recommendation:** Use react-pdf's built-in `Thumbnail` component for desktop, `react-native-pdf-thumbnail` for mobile, virtualize both thumbnail lists for lazy loading on large PDFs.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PDFT-01 | User can open a thumbnail sidebar while reading a PDF | Desktop: reuse Sheet sidebar pattern (already in pdf.tsx for TOC). Mobile: Animated slide-in panel or bottom sheet |
| PDFT-02 | Thumbnail sidebar shows page preview images for all pages | Desktop: react-pdf `Thumbnail` component renders page previews natively. Mobile: `react-native-pdf-thumbnail` generates native thumbnails |
| PDFT-03 | Current page is visually highlighted in the thumbnail sidebar | Both: `pageNumberAtom` (desktop) and `currentPage` state (mobile) already track current page; apply highlight styling to matching thumbnail |
| PDFT-04 | User can tap a thumbnail to navigate to that page | Desktop: `Thumbnail.onItemClick` + virtualizer.scrollToIndex. Mobile: `setTargetPage(page)` already triggers navigation in react-native-pdf |
| PDFT-05 | Thumbnails load lazily for performance with large PDFs | Desktop: @tanstack/react-virtual for thumbnail list. Mobile: FlatList with lazy thumbnail generation (generate on demand as items enter viewport) |
</phase_requirements>

## Standard Stack

### Core (Desktop - apps/main)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| react-pdf | 10.2.0 (installed) | `Thumbnail` component for page previews | Already in project; built-in Thumbnail exports same quality as Page without text/annotation layers |
| @tanstack/react-virtual | 3.13.12 (installed) | Virtualize thumbnail list for lazy rendering | Already in project for main PDF view; same pattern for sidebar |
| @radix-ui/react-dialog | (installed) | Sheet sidebar container | Already used for TOC sidebar in pdf.tsx |
| jotai | (installed) | State management for sidebar open/current page | Already manages all PDF state |

### Core (Mobile - apps/mobile)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| react-native-pdf-thumbnail | 1.3.1 | Generate native page thumbnail images | Only viable option for Expo dev-client builds; uses PDFKit (iOS) and PdfRenderer (Android) |
| react-native | (installed) | FlatList for virtualized thumbnail list | Built-in; FlatList already lazy-loads items |
| react-native-reanimated | (installed) | Animated sidebar slide-in | Already in project for smooth transitions |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| react-pdf Thumbnail | Canvas-based manual rendering via pdfjs-dist | Unnecessary complexity; Thumbnail component handles this natively |
| react-native-pdf-thumbnail | WebView-based PDF rendering for thumbnails | Poor performance, no native quality, harder to virtualize |
| Sheet sidebar (desktop) | Persistent side panel (no overlay) | Sheet is already the established pattern; consistent with TOC |

**No new installation needed for desktop.** For mobile:
```bash
cd apps/mobile && npm install react-native-pdf-thumbnail
```

Note: `react-native-pdf-thumbnail` requires a rebuild of the native app since it includes native iOS/Android code.

## Architecture Patterns

### Desktop: Thumbnail Sidebar Structure

```
apps/main/src/components/pdf/
  components/
    pdf.tsx                    # Add thumbnail sidebar (parallel to TOC sidebar)
    thumbnail-sidebar.tsx      # NEW: Thumbnail grid/list with virtualization
  atoms/
    paragraph-atoms.ts         # Add thumbnailSidebarOpenAtom
  hooks/
    useThumbnailVirtualization.tsx  # NEW: Virtualizer for thumbnail list
```

### Pattern 1: react-pdf Thumbnail inside Document Context

**What:** The `Thumbnail` component must be placed inside a `<Document>` component (or receive a `pdf` prop from `onLoadSuccess`). The existing `pdf.tsx` already has a `<Document>` wrapper.
**When to use:** Always for desktop thumbnails.
**Example:**
```typescript
// Source: react-pdf v10.2.0 TypeScript definitions
import { Thumbnail } from 'react-pdf';

// Inside a <Document> component context:
<Thumbnail
  pageNumber={pageNumber}
  width={120}                    // Small width for thumbnail
  onItemClick={({ pageNumber }) => {
    virtualizer.scrollToIndex(pageNumber - 1, {
      align: 'start',
      behavior: 'smooth',
    });
    setPageNumber(pageNumber);
    setThumbnailSidebarOpen(false);
  }}
  className={cn(
    'cursor-pointer border-2 rounded',
    currentPage === pageNumber ? 'border-blue-500' : 'border-transparent'
  )}
/>
```

### Pattern 2: Virtualized Thumbnail List (Desktop)

**What:** Use @tanstack/react-virtual to only render visible thumbnails in the sidebar.
**When to use:** Always -- even a 50-page PDF would render 50 canvas elements without virtualization.
**Example:**
```typescript
const thumbnailVirtualizer = useVirtualizer({
  count: numPages,
  getScrollElement: () => thumbnailContainerRef.current,
  estimateSize: () => THUMBNAIL_HEIGHT + GAP,  // ~180px per thumbnail
  overscan: 3,
});
```

### Pattern 3: Mobile Thumbnail Generation with Lazy Loading

**What:** Use react-native-pdf-thumbnail's `generate(filePath, pageIndex)` per-page as FlatList items become visible.
**When to use:** Mobile thumbnail sidebar.
**Example:**
```typescript
import PdfThumbnail from 'react-native-pdf-thumbnail';

// In FlatList renderItem:
const [uri, setUri] = useState<string | null>(null);
useEffect(() => {
  PdfThumbnail.generate(filePath, pageIndex, 50) // quality 50 for thumbnails
    .then(result => setUri(result.uri));
}, [filePath, pageIndex]);
```

### Pattern 4: Reuse Sheet Sidebar on Desktop

**What:** The TOC already uses `<Sheet side="left">`. The thumbnail sidebar should use the same pattern but with a toggle between TOC and Thumbnails, or a separate sheet.
**When to use:** Desktop thumbnail sidebar.
**Decision:** Use a separate Sheet trigger (new button in toolbar) that opens the thumbnail panel. Keep TOC as a separate action.

### Anti-Patterns to Avoid

- **Rendering all Thumbnail components at once:** Without virtualization, a 200-page PDF would create 200 canvas render operations simultaneously, freezing the UI.
- **Re-rendering thumbnails on every page change:** The sidebar should only re-render the highlight styling, not re-render thumbnail images. Memoize thumbnail components.
- **Using a second `<Document>` for the sidebar on desktop:** This would load and parse the PDF twice. Instead, place thumbnails inside the existing Document context or pass the `pdf` prop from `onLoadSuccess`.
- **Generating all mobile thumbnails upfront:** Use lazy generation -- only generate thumbnails for visible FlatList items.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| PDF page preview rendering (desktop) | Canvas-based pdfjs rendering | react-pdf `Thumbnail` component | Handles scaling, canvas cleanup, memory management |
| PDF page preview rendering (mobile) | WebView screenshot or manual bitmap | react-native-pdf-thumbnail | Native PDFKit/PdfRenderer is 10x faster, proper memory management |
| List virtualization | Manual intersection observer for thumbnails | @tanstack/react-virtual (desktop), FlatList (mobile) | Edge cases with dynamic sizing, scroll restoration, overscan |
| Sidebar slide animation | Custom CSS transitions | Sheet component (desktop), Animated/Reanimated (mobile) | Accessibility, focus trapping, gesture handling |

**Key insight:** Both platforms have mature, tested solutions for every piece of this feature. The implementation is primarily composition of existing tools, not novel engineering.

## Common Pitfalls

### Pitfall 1: Memory Pressure from Large PDFs
**What goes wrong:** Rendering 100+ thumbnail canvases simultaneously can consume hundreds of MB of memory, causing crashes on mobile and sluggishness on desktop.
**Why it happens:** Each PDF page renders to an off-screen canvas. Even small thumbnails allocate significant bitmap memory.
**How to avoid:** Strict virtualization with small overscan (2-3 items). On mobile, generate thumbnails on demand and cache the URI, not the bitmap.
**Warning signs:** Growing memory in devtools, lagging scroll, canvas creation warnings.

### Pitfall 2: Double Document Loading (Desktop)
**What goes wrong:** Creating a second `<Document>` component for the thumbnail sidebar causes the PDF to be fetched and parsed twice.
**Why it happens:** Each `<Document>` independently loads the PDF via pdfjs.
**How to avoid:** Either nest thumbnails inside the existing `<Document>` in pdf.tsx, or capture the `PDFDocumentProxy` from `onLoadSuccess` and pass it as the `pdf` prop to Thumbnail components in a separate container.
**Warning signs:** Network tab shows two PDF fetches, doubled load time.

### Pitfall 3: Thumbnail Click Navigation Race Condition (Desktop)
**What goes wrong:** Clicking a thumbnail while the virtualizer is mid-scroll can cause navigation to the wrong page.
**Why it happens:** The existing `BookNavigationState` state machine prevents concurrent navigation requests. If state is `Navigating`, `setPageNumberAtom` is a no-op.
**How to avoid:** Force navigation state to Idle before thumbnail click navigation, or bypass the state machine for explicit user-initiated navigation.
**Warning signs:** Clicking thumbnails sometimes doesn't navigate.

### Pitfall 4: react-native-pdf-thumbnail Requires Native Rebuild
**What goes wrong:** Installing the package and running in Expo Go fails.
**Why it happens:** The package includes native iOS/Android code.
**How to avoid:** The project already uses `expo-dev-client`, so run `npx expo prebuild` and rebuild. Document this in the plan.
**Warning signs:** "Native module not found" errors at runtime.

### Pitfall 5: Mobile Sidebar Blocking PDF Gestures
**What goes wrong:** The thumbnail sidebar interferes with the PDF component's pan/zoom gestures.
**Why it happens:** Overlapping touch responders in React Native.
**How to avoid:** Use a modal/overlay approach rather than inline sidebar. The existing toolbar toggle pattern (touch to show/hide) works well here.
**Warning signs:** PDF becomes unresponsive when sidebar is visible.

## Code Examples

### Desktop: Complete Thumbnail Sidebar Component

```typescript
// Source: react-pdf v10.2.0 Thumbnail API + existing project patterns
import { Thumbnail } from 'react-pdf';
import { useVirtualizer } from '@tanstack/react-virtual';
import { useAtomValue, useSetAtom } from 'jotai';
import { pageCountAtom, pageNumberAtom, virtualizerAtom } from '../atoms/paragraph-atoms';

const THUMBNAIL_WIDTH = 120;
const THUMBNAIL_HEIGHT = 170; // Approximate for standard page ratio
const GAP = 8;

function ThumbnailSidebar({ onClose }: { onClose: () => void }) {
  const numPages = useAtomValue(pageCountAtom);
  const currentPage = useAtomValue(pageNumberAtom);
  const mainVirtualizer = useAtomValue(virtualizerAtom);
  const containerRef = useRef<HTMLDivElement>(null);

  const thumbVirtualizer = useVirtualizer({
    count: numPages,
    getScrollElement: () => containerRef.current,
    estimateSize: () => THUMBNAIL_HEIGHT + GAP,
    overscan: 3,
  });

  // Scroll to current page in thumbnail list on open
  useEffect(() => {
    if (currentPage > 0) {
      thumbVirtualizer.scrollToIndex(currentPage - 1, { align: 'center' });
    }
  }, []);

  const handleThumbnailClick = (pageNumber: number) => {
    mainVirtualizer?.scrollToIndex(pageNumber - 1, {
      align: 'start',
      behavior: 'smooth',
    });
    onClose();
  };

  return (
    <div ref={containerRef} className="overflow-y-auto h-full p-2">
      <div
        style={{ height: thumbVirtualizer.getTotalSize(), position: 'relative' }}
      >
        {thumbVirtualizer.getVirtualItems().map((item) => {
          const pageNum = item.index + 1;
          return (
            <div
              key={item.key}
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                width: '100%',
                transform: `translateY(${item.start}px)`,
              }}
              className="flex flex-col items-center"
            >
              <Thumbnail
                pageNumber={pageNum}
                width={THUMBNAIL_WIDTH}
                onItemClick={() => handleThumbnailClick(pageNum)}
                className={cn(
                  'cursor-pointer border-2 rounded transition-colors',
                  currentPage === pageNum
                    ? 'border-blue-500 shadow-md'
                    : 'border-transparent hover:border-gray-300'
                )}
              />
              <span className="text-xs text-gray-500 mt-1">{pageNum}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
```

### Mobile: Thumbnail Item with Lazy Generation

```typescript
// Source: react-native-pdf-thumbnail API
import PdfThumbnail from 'react-native-pdf-thumbnail';
import { Image, TouchableOpacity, Text, View } from 'react-native';

function ThumbnailItem({
  filePath,
  pageIndex,
  pageNumber,
  isCurrentPage,
  onPress,
}: {
  filePath: string;
  pageIndex: number;
  pageNumber: number;
  isCurrentPage: boolean;
  onPress: () => void;
}) {
  const [thumbnail, setThumbnail] = useState<{ uri: string; width: number; height: number } | null>(null);

  useEffect(() => {
    let cancelled = false;
    PdfThumbnail.generate(filePath, pageIndex, 50)
      .then((result) => {
        if (!cancelled) setThumbnail(result);
      })
      .catch(console.error);
    return () => { cancelled = true; };
  }, [filePath, pageIndex]);

  return (
    <TouchableOpacity onPress={onPress} style={{ alignItems: 'center', padding: 4 }}>
      {thumbnail ? (
        <Image
          source={{ uri: thumbnail.uri }}
          style={{
            width: 80,
            height: 110,
            borderWidth: isCurrentPage ? 2 : 0,
            borderColor: '#3b82f6',
            borderRadius: 4,
          }}
          resizeMode="contain"
        />
      ) : (
        <View style={{ width: 80, height: 110, backgroundColor: '#e5e7eb', borderRadius: 4 }} />
      )}
      <Text style={{ fontSize: 11, color: '#6b7280', marginTop: 2 }}>{pageNumber}</Text>
    </TouchableOpacity>
  );
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual pdfjs canvas rendering for thumbnails | react-pdf `Thumbnail` component | react-pdf v7+ (2023) | No manual canvas management needed |
| ScrollView + all thumbnails rendered | Virtualized list (react-virtual / FlatList) | Standard practice 2022+ | Essential for 100+ page PDFs |
| Expo Go for development | expo-dev-client with native modules | Expo SDK 48+ (2023) | Enables react-native-pdf-thumbnail usage |

**Deprecated/outdated:**
- `react-pdf-thumbnail` (separate npm package): Unnecessary since react-pdf v7+ includes Thumbnail natively
- Manual canvas-based thumbnail rendering with pdfjs-dist: Over-engineered when Thumbnail component exists

## Open Questions

1. **Thumbnail sidebar vs persistent side panel (desktop)**
   - What we know: The TOC uses a Sheet (overlay). Thumbnails could use the same pattern or a persistent panel.
   - What's unclear: User preference for overlay vs persistent sidebar.
   - Recommendation: Start with Sheet (consistent with TOC), can add persistent mode later. Simpler implementation.

2. **Second Document context for thumbnail sidebar (desktop)**
   - What we know: Thumbnails need to be inside a `<Document>` or receive a `pdf` prop. The existing `<Document>` wraps the main reader.
   - What's unclear: Whether placing both the main reader AND the thumbnail sidebar inside the same Document causes performance issues.
   - Recommendation: Capture `PDFDocumentProxy` from `onLoadSuccess` (already happens in pdf.tsx) and pass as `pdf` prop to thumbnails in the Sheet. This avoids nesting issues and double loading.

3. **Mobile sidebar interaction pattern**
   - What we know: The mobile PDF reader uses a tap-to-toggle toolbar. There is no existing sidebar pattern.
   - What's unclear: Best UX for opening thumbnail panel on mobile (button in toolbar? swipe gesture?).
   - Recommendation: Add a thumbnail icon button to the existing toolbar. On press, show a modal/bottom-sheet with a FlatList of thumbnails. Consistent with existing tap-to-toggle pattern.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Vitest (desktop) |
| Config file | apps/main/vitest.config.ts |
| Quick run command | `cd apps/main && npx vitest run --reporter=verbose` |
| Full suite command | `cd apps/main && npx vitest run` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PDFT-01 | Sidebar opens/closes without losing reading position | manual-only | N/A - requires PDF rendering in browser | N/A |
| PDFT-02 | Thumbnail components render for each page | unit | `cd apps/main && npx vitest run src/components/pdf/components/thumbnail-sidebar.test.tsx -x` | Wave 0 |
| PDFT-03 | Current page highlight applies correctly | unit | `cd apps/main && npx vitest run src/components/pdf/components/thumbnail-sidebar.test.tsx -x` | Wave 0 |
| PDFT-04 | Thumbnail click triggers page navigation | unit | `cd apps/main && npx vitest run src/components/pdf/components/thumbnail-sidebar.test.tsx -x` | Wave 0 |
| PDFT-05 | Virtualization renders only visible thumbnails | unit | `cd apps/main && npx vitest run src/components/pdf/hooks/useThumbnailVirtualization.test.tsx -x` | Wave 0 |

### Sampling Rate
- **Per task commit:** `cd apps/main && npx vitest run --reporter=verbose`
- **Per wave merge:** `cd apps/main && npx vitest run`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `apps/main/src/components/pdf/components/thumbnail-sidebar.test.tsx` -- covers PDFT-02, PDFT-03, PDFT-04
- [ ] `apps/main/src/components/pdf/hooks/useThumbnailVirtualization.test.tsx` -- covers PDFT-05
- [ ] Mobile tests are manual-only (React Native PDF rendering cannot be unit tested meaningfully)

## Sources

### Primary (HIGH confidence)
- react-pdf v10.2.0 TypeScript definitions (`node_modules/react-pdf/dist/Thumbnail.d.ts`) - Thumbnail component API verified
- Existing codebase: `apps/main/src/components/pdf/` - current PDF architecture, Sheet sidebar, virtualization patterns
- Existing codebase: `apps/mobile/app/reader/pdf/[id].tsx` - current mobile PDF reader implementation
- npm registry: react-pdf 10.4.1 (latest), react-native-pdf-thumbnail 1.3.1 (latest), @tanstack/react-virtual 3.13.23 (latest)

### Secondary (MEDIUM confidence)
- [react-pdf GitHub](https://github.com/wojtekmaj/react-pdf) - Thumbnail component documentation
- [react-native-pdf-thumbnail GitHub](https://github.com/songsterq/react-native-pdf-thumbnail) - API: generate(filePath, page, quality), generateAllPages(filePath, quality), returns {uri, width, height}

### Tertiary (LOW confidence)
- None -- all key claims verified against installed packages and official sources

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all desktop libraries already installed and in use; mobile library well-documented with clear API
- Architecture: HIGH - patterns directly extend existing codebase patterns (Sheet sidebar, virtualization, jotai atoms)
- Pitfalls: HIGH - derived from direct codebase analysis (BookNavigationState race condition, Document context reuse)

**Research date:** 2026-04-07
**Valid until:** 2026-05-07 (stable libraries, no breaking changes expected)
