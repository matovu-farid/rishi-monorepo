# Mobile Book Rendering Research: EPUB + PDF

**Domain:** Mobile EPUB and PDF rendering for React Native / Expo
**Researched:** 2026-04-05
**Overall confidence:** MEDIUM-HIGH

---

## Executive Summary

The React Native ecosystem for book rendering is split into two clear tiers: WebView-based solutions (epub.js running inside a WebView) and native rendering solutions (Readium SDK wrapping platform-native engines). For EPUB, the pragmatic choice is **@epubjs-react-native/core** -- it runs epub.js inside a WebView, has explicit Expo support via `@epubjs-react-native/expo-file-system`, and provides the closest API parity with the desktop app's existing `react-reader` / epubjs usage. For PDF, **react-native-pdf** remains the most battle-tested option, though it requires an Expo development build (not Expo Go). The newer **react-native-pdf-jsi** offers compelling JSI-based performance but is less proven. File picking is well-solved by Expo SDK 54's upgraded `expo-file-system` (new File/Directory classes) combined with `expo-document-picker`.

Commercial reading apps like Kindle and Apple Books all use WebView-based rendering for reflowable EPUB content -- this validates the WebView approach as production-grade, not a compromise.

---

## 1. EPUB Rendering Libraries

### Recommendation: @epubjs-react-native/core

**Use this because** it wraps epub.js in a WebView, meaning the rendering engine is identical to what the desktop app already uses. This maximizes code sharing for themes, CFI-based position tracking, and annotation logic.

| Library | Stars | Last Update | Expo Support | Highlights | Search | Pagination | Maturity |
|---------|-------|-------------|-------------|------------|--------|------------|----------|
| **@epubjs-react-native/core** | 240 | Jan 2025 (v1.4.7) | YES (dedicated package) | YES | YES | YES | Good |
| react-native-readium | 155 | Mar 2026 (v5.0.0-rc) | YES (config plugin) | YES | Partial | YES | Moderate (still RC) |
| epubjs-rn (FuturePress) | Legacy | Stale | NO | NO | NO | YES | Abandoned |

### @epubjs-react-native/core -- Detailed Analysis

**Confidence: MEDIUM-HIGH** (verified via GitHub README, npm, community posts)

**Architecture:** Runs epub.js inside a `react-native-webview`. The Reader component accepts epub/opf/base64 sources and exposes a `useReader()` hook for all interactions.

**Feature set:**
- Pagination and scrolled reading modes (`paginated`, `scrolled`, `scrolled-continuous`)
- Text selection with customizable context menu actions
- Annotations: `addAnnotation()`, `updateAnnotation()`, `removeAnnotation()`
- Bookmarks: `addBookmark()`, `updateBookmark()`, `removeBookmark()`
- Search: `search()` / `clearSearchResults()`
- Theme customization: `changeFontSize()`, `changeFontFamily()`, `changeTheme()`
- Navigation: `goNext()`, `goPrevious()`, `goToLocation(cfi)` -- uses the same ePubCFI system as desktop
- Swipe gestures enabled by default

**Expo installation:**
```bash
npx expo install @epubjs-react-native/core @epubjs-react-native/expo-file-system react-native-webview react-native-gesture-handler
```

**Key props:**
- `src` -- book source (base64, file path, or URL)
- `fileSystem` -- file system handler (use the expo-file-system adapter)
- `initialLocation` -- ePubCFI string (same format as desktop)
- `enableSwipe`, `enableSelection`, `flow`, `defaultTheme`

**Parity with desktop app:**
The desktop app uses `react-reader` which wraps epubjs. The mobile library wraps the same epubjs engine. CFI-based locations, theme overrides, and rendition concepts are shared. The highlight/annotation APIs differ in surface but the underlying ePubCFI references are compatible -- meaning cross-device sync of positions and highlights is architecturally straightforward.

**Limitations:**
- WebView overhead: slightly slower than native rendering, but adequate for text-heavy EPUB content
- 21 open GitHub issues (manageable for a 240-star project)
- Last release Jan 2025 -- not abandoned, but not rapidly iterating
- Scripted EPUB content disabled by default on Android

### react-native-readium -- Alternative Analysis

**Confidence: MEDIUM** (actively maintained but still in RC for v5)

**Architecture:** Wraps the Readium SDK, which uses platform-native rendering engines (not WebView). This means better performance for complex layouts but a completely different rendering pipeline from the desktop app.

**Strengths:**
- Native rendering = smoother performance for complex EPUBs
- Active maintenance (March 2026 release)
- Built-in decoration/highlight system with selection actions
- Supports EPUB 2 and 3
- Uses Nitro Modules (modern RN architecture)

**Weaknesses:**
- Only 155 stars, still on RC releases (v5.0.0-rc.17)
- No API parity with epubjs -- different position system, different annotation model
- Requires Xcode 16.2+, Swift 6.0, JDK 17 (heavier build requirements)
- No PDF support yet (on roadmap)
- No DRM support yet
- Cross-device sync with desktop would require translating between Readium's position model and epubjs CFI

**Verdict:** Better long-term technology, but wrong choice for this project. The desktop app is built on epubjs, and maintaining two different position/annotation systems across desktop and mobile adds significant sync complexity for marginal rendering improvement.

---

## 2. PDF Rendering Libraries

### Recommendation: react-native-pdf (primary) with react-native-pdf-jsi as upgrade path

| Library | Stars | Expo Support | Native Rendering | Annotations | Search | Performance |
|---------|-------|-------------|-----------------|-------------|--------|-------------|
| **react-native-pdf** | ~2000+ | Dev build only | YES (PDFKit/AndroidPdfViewer) | Read-only | NO | Good |
| react-native-pdf-jsi | 46 | Dev build only | YES + JSI bridge | Highlights | YES | Excellent |
| @kishannareshpal/expo-pdf | 7 | YES (npx expo install) | YES (PDFKit/PDFium) | NO | NO | Good |
| pdf-viewer-expo | Low | YES (Expo Go) | NO (WebView + PDF.js) | NO | NO | Poor |

### react-native-pdf -- Detailed Analysis

**Confidence: HIGH** (well-established, widely used)

**Architecture:** Uses native PDF rendering engines -- PDFKit on iOS, AndroidPdfViewer on Android. Renders directly in native views, not WebView.

**Feature set:**
- Load from URL, local file, base64, or asset with caching
- Horizontal/vertical display modes
- Pinch-to-zoom, double-tap zoom, drag
- Password-protected PDF support
- Page navigation via `setPage(pageNumber)`
- Annotation rendering (read-only, iOS only via `enableAnnotationRendering`)
- RTL support (iOS only)

**Expo setup:** Requires development build (not Expo Go). Use the config plugin:
```json
{
  "expo": {
    "plugins": ["react-native-pdf"]
  }
}
```

```bash
npm install react-native-pdf react-native-blob-util
npx expo prebuild
```

**Limitations:**
- No built-in text search
- No user-created annotations (only renders existing ones)
- Not Expo Go compatible
- Some features platform-specific

### react-native-pdf-jsi -- Upgrade Path

**Confidence: LOW-MEDIUM** (newer, less proven, impressive claims need validation)

**Why consider it:** JSI bridge eliminates the React Native bridge overhead. Claims 80x faster rendering, constant 2MB memory usage, text search with bounding rectangles, bookmark support, highlight rendering, and PDF manipulation (split/merge/compress).

**Why not use it now:** Only 46 stars, 7 open issues, less battle-tested. The performance claims are impressive but the project is young. Use react-native-pdf initially, evaluate react-native-pdf-jsi as a drop-in replacement in a later phase.

### @kishannareshpal/expo-pdf -- Lightweight Alternative

**Confidence: MEDIUM** (small project but clean API, works well with Expo)

Only 7 stars but clean implementation using PDFKit (iOS) and PDFium (Android). Simpler API than react-native-pdf. No annotation support. Good for basic viewing but lacks the feature depth needed for a full reading app.

---

## 3. epub.js in WebView -- Can It Work?

**Yes, and this is exactly what @epubjs-react-native does.**

The desktop app runs epub.js in a Tauri WebView. The mobile equivalent runs epub.js in a React Native WebView via `@epubjs-react-native/core`. The rendering engine is the same -- epub.js parses the EPUB, renders chapters into the WebView using CSS columns for pagination.

### Tradeoffs of the WebView Approach

| Aspect | WebView (epubjs) | Native (Readium) |
|--------|------------------|-------------------|
| **Rendering fidelity** | Depends on platform WebView engine | Platform-native |
| **Performance** | Adequate for text; slower for complex layouts | Better for complex EPUBs |
| **Memory** | Higher (WebView process) | Lower |
| **API parity with desktop** | HIGH -- same epub.js API | LOW -- different system |
| **Position format** | ePubCFI (same as desktop) | Readium Locator (different) |
| **Theme system** | CSS overrides (same as desktop) | Native theme props |
| **Ecosystem** | Mature (epub.js is well-established) | Mature (Readium is industry standard) |
| **Build complexity** | Simple (just WebView) | Higher (native SDKs, JDK 17, Xcode 16.2+) |

**Recommendation:** The WebView approach is the correct choice for this project. Kindle, Apple Books, Kobo, and Libby all use WebView-based rendering for EPUB content on mobile. The performance difference is negligible for reflowable text content. The API parity with the desktop app is the decisive factor.

### Rolling Your Own vs Using @epubjs-react-native

You could embed epub.js directly in a `react-native-webview` with a custom HTML template. This gives maximum control but means rebuilding the Reader component, navigation, annotation injection, and gesture handling from scratch.

**Do not do this.** Use @epubjs-react-native/core. It already handles: WebView communication bridge, gesture integration, epub.js lifecycle, file system adapter for Expo, and exposes a clean React hook API. Building this yourself would take weeks and produce a worse result.

---

## 4. How Commercial Reading Apps Handle Rendering

**Confidence: MEDIUM** (based on public information, reverse engineering reports, and Readium architecture docs)

| App | EPUB Rendering | PDF Rendering | Key Approach |
|-----|---------------|---------------|-------------|
| **Kindle** | Custom WebView-based engine (KFX format internally, converts EPUB) | Custom native renderer | Proprietary format conversion; heavy server-side processing |
| **Apple Books** | WebView with strong EPUB3/CSS support | PDFKit (native) | Best-in-class CSS rendering; uses platform WebView engine |
| **Kobo** | WebView-based with Readium components | Native | Open-source Readium contributions |
| **Libby** | WebView-based | WebView (PDF.js or similar) | Progressive web app architecture |
| **Google Play Books** | WebView-based | Native PDF renderer | Server-side pre-processing of content |

**Key takeaway:** Every major reading app uses a WebView for EPUB rendering. This is the industry standard, not a compromise. The differentiators are in the surrounding features (sync, DRM, discovery) not the rendering engine.

---

## 5. File Picking on Expo

### Recommendation: expo-document-picker + expo-file-system (SDK 54 new API)

**Confidence: HIGH** (official Expo packages, well-documented)

Expo SDK 54 introduced a major upgrade to `expo-file-system` with new `File` and `Directory` classes. Combined with `expo-document-picker`, this provides a complete file import pipeline.

### Architecture

```
User taps "Import Book"
  --> expo-document-picker opens system file picker
  --> User selects .epub or .pdf file
  --> File URI returned (SAF URI on Android, Security Scoped Resource on iOS)
  --> expo-file-system copies to app's document directory
  --> Book available for offline reading
```

### Implementation Notes

**expo-document-picker:**
```bash
npx expo install expo-document-picker
```
- Filter by MIME type: `application/epub+zip` for EPUB, `application/pdf` for PDF
- Set `copyToCacheDirectory: true` to ensure the file is readable by expo-file-system immediately
- Returns file URI, name, size, and MIME type

**expo-file-system (SDK 54 new API):**
```bash
npx expo install expo-file-system
```
- New `File` and `Directory` classes replace the old callback-based API
- Built-in SAF URI support on Android (handles content:// URIs from document picker)
- iOS Security Scoped Resources supported natively
- Streams and FileHandle for large file operations
- Works with `expo/fetch` for downloading books from URLs

**Critical gotcha:** On Android, the document picker returns SAF URIs (`content://...`) which older expo-file-system could not read directly. The SDK 54 API handles this natively. If for any reason you need the legacy API, you must set `copyToCacheDirectory: true` in the picker options.

### File Storage Strategy

Store imported books in the app's document directory:
```
<app-documents>/books/<book-id>/
  book.epub (or book.pdf)
  metadata.json
  cover.jpg (extracted)
```

This directory persists across app updates and is included in device backups. Use `expo-file-system`'s `Directory` class to manage this structure.

---

## 6. Recommended Stack Summary

| Concern | Library | Version | Why |
|---------|---------|---------|-----|
| EPUB rendering | @epubjs-react-native/core | ^1.4.7 | API parity with desktop epubjs; Expo support; highlights, search, pagination |
| EPUB file system adapter | @epubjs-react-native/expo-file-system | Latest | Required companion for Expo projects |
| PDF rendering | react-native-pdf | Latest | Battle-tested native rendering; config plugin for Expo dev builds |
| WebView (EPUB dep) | react-native-webview | Latest | Required by @epubjs-react-native |
| File picking | expo-document-picker | SDK 54 | System file picker with MIME type filtering |
| File management | expo-file-system | SDK 54 (new API) | File/Directory classes, SAF support, streams |
| Gestures (EPUB dep) | react-native-gesture-handler | Latest | Required by @epubjs-react-native |

### Installation

```bash
# EPUB rendering
npx expo install @epubjs-react-native/core @epubjs-react-native/expo-file-system react-native-webview react-native-gesture-handler

# PDF rendering (requires dev build, not Expo Go)
npm install react-native-pdf react-native-blob-util

# File import
npx expo install expo-document-picker expo-file-system
```

### Build Requirements

- **Expo Development Build required** (not Expo Go) -- react-native-pdf uses native modules
- Add to `app.json` plugins: `["react-native-pdf"]`
- Run `npx expo prebuild` before building

---

## 7. Cross-Device Sync Implications

Because both desktop and mobile will use epub.js for EPUB rendering, the position format (ePubCFI strings) is shared. This means:

- **Reading progress sync:** Store the ePubCFI string on the server. Both platforms produce and consume the same format.
- **Highlight sync:** Both platforms use epub.js annotation APIs with ePubCFI ranges. Store the CFI range + color + note on the server.
- **Theme sync:** Theme names/values can be shared, though CSS details may differ slightly between desktop WebView and mobile WebView.

For PDF, positions are page numbers, which are inherently portable across platforms.

---

## 8. Pitfalls and Risks

### Critical

**WebView memory on older Android devices:** epub.js in a WebView consumes more memory than native rendering. On low-end Android devices (2-3GB RAM), loading large EPUBs (50MB+) while other app features are active could cause OOM crashes. **Mitigation:** Test on low-end devices early; implement memory monitoring; unload WebView when navigating away from reader.

**Expo Go incompatibility:** react-native-pdf requires native modules, so the entire app must use Expo development builds from the start. This affects the developer experience -- no scanning QR codes from Expo Go. **Mitigation:** Set up EAS Build early; use `expo-dev-client` for development.

### Moderate

**@epubjs-react-native maintenance cadence:** Last release Jan 2025. If a blocking bug is found, the project may not respond quickly. **Mitigation:** Fork the repo as insurance; the codebase is relatively small (WebView bridge + epub.js integration).

**Android SAF URI handling:** While SDK 54 expo-file-system supports SAF URIs, edge cases exist with specific file providers (Google Drive, OneDrive). **Mitigation:** Always copy picked files to the app's document directory rather than reading from SAF URIs directly.

**PDF annotation creation:** react-native-pdf only renders existing annotations; it cannot create new ones. If user-created PDF annotations are a requirement, you will need either react-native-pdf-jsi (highlight rects only) or a commercial SDK (Nutrient/PSPDFKit, ComPDFKit). **Mitigation:** Defer PDF annotation creation to a later phase; focus on EPUB annotations first since that is the primary format.

### Minor

**epub.js rendering differences:** The mobile WebView engine (WKWebView on iOS, Chrome WebView on Android) may render CSS slightly differently than the Tauri WebView (WebKit on macOS, WebView2/Edge on Windows). **Mitigation:** Test the same EPUB on both platforms; keep theme CSS simple; avoid relying on obscure CSS features.

---

## 9. Phase Implementation Recommendations

1. **Phase 1: EPUB Reader** -- Implement @epubjs-react-native/core with basic navigation, themes, and position tracking. This is the core reading experience and validates the WebView approach.

2. **Phase 2: File Import** -- Add expo-document-picker and file management. Users can import EPUBs from device storage.

3. **Phase 3: PDF Reader** -- Add react-native-pdf. This requires the Expo dev build setup from Phase 1.

4. **Phase 4: Annotations & Highlights** -- Build on top of @epubjs-react-native's annotation API for EPUB. Sync with desktop via shared ePubCFI format.

5. **Phase 5: Cross-Device Sync** -- Implement position and highlight sync using the shared CFI format. PDF position sync via page numbers.

---

## Sources

- [@epubjs-react-native/core - GitHub](https://github.com/victorsoares96/epubjs-react-native) -- 240 stars, MIT license, Expo support
- [@epubjs-react-native/core - npm](https://www.npmjs.com/package/@epubjs-react-native/core) -- v1.4.7, Jan 2025
- [react-native-readium - GitHub](https://github.com/5-stones/react-native-readium) -- 155 stars, v5.0.0-rc.17, Mar 2026
- [react-native-readium - npm](https://www.npmjs.com/package/react-native-readium) -- 293 downloads/month
- [react-native-pdf - GitHub](https://github.com/wonday/react-native-pdf) -- battle-tested native PDF rendering
- [react-native-pdf-jsi - GitHub](https://github.com/126punith/react-native-pdf-jsi) -- 46 stars, JSI-powered
- [@kishannareshpal/expo-pdf - GitHub](https://github.com/kishannareshpal/expo-pdf) -- 7 stars, clean Expo integration
- [expo-document-picker - Expo Docs](https://docs.expo.dev/versions/latest/sdk/document-picker/)
- [expo-file-system SDK 54 upgrade - Expo Blog](https://expo.dev/blog/expo-file-system) -- new File/Directory API
- [epub reader for React Native EXPO - DEV Community](https://dev.to/afrazs/epub-reader-for-react-native-expo-28m2)
- [@epubjs-react-native/expo-file-system - npm](https://www.npmjs.com/package/@epubjs-react-native/expo-file-system)
