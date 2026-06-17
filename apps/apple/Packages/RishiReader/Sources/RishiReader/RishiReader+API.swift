// RishiReader — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiReader exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiReader is the EPUB + PDF reader. EPUB rendering is delegated
// to Readium; PDF to PDFKit. The package owns the SwiftUI screens,
// the view models, theme/typography settings, highlight overlays,
// and the prewarm cache that hides cold-open latency.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 2 unused exports).

// MARK: - Views (EPUB)
//
// EPUBReaderScreen            — `UI/EPUBReaderScreen.swift`. Full-screen EPUB reader (toolbar
//                                + EPUBReaderView + sheets).
// EPUBReaderView              — `EPUB/EPUBReaderView.swift`. UIViewControllerRepresentable
//                                wrapping Readium's EPUBNavigator.
// EPUBTOCView                 — `UI/EPUBTOCView.swift`. Table-of-contents sheet for EPUB.
// EPUBThemePicker             — `UI/EPUBThemePicker.swift`. Theme picker (light/dark/sepia).
// EPUBTypographyPicker        — `UI/EPUBTypographyPicker.swift`. Font/size/line-height picker.
// EPUBProgressIndicator       — `UI/EPUBProgressIndicator.swift`. Progress bar at the bottom.
// EPUBHighlightContextMenu    — `UI/EPUBHighlightContextMenu.swift`. Selection menu over EPUB.

// MARK: - Views (PDF)
//
// PDFReaderScreen             — `UI/PDFReaderScreen.swift`. Full-screen PDF reader (toolbar
//                                + PDFReaderView + sheets).
// PDFReaderView               — `PDF/PDFReaderView.swift`. UIViewRepresentable wrapping
//                                PDFKit's PDFView.
// PDFTOCView                  — `UI/PDFTOCView.swift`. Outline sheet for PDF.
// PDFThemePicker              — `UI/PDFThemePicker.swift`. Theme picker for PDF.
// PDFPageIndicator            — `UI/PDFPageIndicator.swift`. "Page n of N" overlay.
// PDFHighlightOverlay         — `PDF/PDFHighlightOverlay.swift`. Renders highlight rectangles
//                                on top of a PDF page.

// MARK: - Views (shared)
//
// HighlightContextMenu        — `UI/HighlightContextMenu.swift`. Selection menu (format-agnostic).
// HighlightNoteEditor         — `UI/HighlightNoteEditor.swift`. Sheet to attach a note to a highlight.

// MARK: - View models
//
// EPUBReaderViewModel         — `EPUB/EPUBReaderViewModel.swift`. @unchecked Sendable. State
//                                + actions for EPUBReaderScreen (position, highlights, sheet).
// PDFReaderViewModel          — `PDF/PDFReaderViewModel.swift`. @unchecked Sendable. State
//                                + actions for PDFReaderScreen.

// MARK: - Coordinators / Flows
//
// EPUBNavigatorCoordinator    — `EPUB/EPUBNavigatorCoordinator.swift`. NSObject. Glue between
//                                EPUBReaderView and Readium delegates.
// EPUBCoordinatorRef          — `EPUB/EPUBReaderView.swift`. Reference-cell that lets the
//                                view model keep a weak handle on the coordinator across
//                                SwiftUI updates.
// ReaderChromeController      — `UI/ReaderChromeController.swift`. Auto-hides the reader
//                                toolbar after idle, restores it on tap. Manages status-bar
//                                + navigation-bar visibility.
// ReaderVoicePresenter        — `UI/ReaderVoicePresenter.swift`. Protocol the reader uses to
//                                launch the voice session without depending on RishiVoice.
// AccessibilityProviding      — `UI/ReaderChromeController.swift`. Protocol; UIKit-backed
//                                implementation reads UIAccessibility settings.
// UIKitAccessibilityProvider  — `UI/ReaderChromeController.swift`. The default implementation.
// ReaderHaptics               — `UI/ReaderHaptics.swift`. Centralised haptic feedback hooks.

// MARK: - Models / Types
//
// ReaderTheme                 — `Model/ReaderTheme.swift`. .light / .dark / .sepia.
// ReaderFontFamily            — `Model/ReaderFontFamily.swift`. The supported EPUB fonts.
// ReaderFontSize              — `Model/ReaderFontSize.swift`. Numeric font-size value type.
// ReaderLineHeight            — `Model/ReaderLineHeight.swift`. Numeric line-height value type.
// ReaderTypography            — `Model/ReaderTypography.swift`. Bundle of family + size + line height.
// ReaderRoute                 — `UI/ReaderRoute.swift`. Enum routing into the reader (epub/pdf + book id).
// ReaderSheet                 — `UI/ReaderSheet.swift`. Enum of sheets the reader can present.
// ReaderLoadingState          — `ReaderLoadingState.swift`. .idle / .loading / .ready / .failed.
// ReaderTapRegionResolver     — `UI/ReaderTapRegionResolver.swift`. Maps tap location -> .prev /
//                                .next / .toggleChrome.
// EPUBHighlightLocator        — `EPUB/EPUBHighlightLocator.swift`. JSON-encodable EPUB locator
//                                used by HighlightStore rows.
// EPUBPositionLocator         — `EPUB/EPUBPositionLocator.swift`. JSON-encodable EPUB position
//                                used by PositionStore rows.
// PDFHighlightLocator         — `Model/PDFHighlightLocator.swift`. JSON-encodable PDF locator
//                                used by HighlightStore rows.
// EPUBSpreadMode              — `EPUB/EPUBPreferencesBridge.swift`. .single / .double.
// PDFOutlineNode              — `PDF/PDFOutlineNode.swift`. A node in the PDF outline tree.
// PlatformImage               — `PDF/PDFThumbnailCache.swift`. UIImage on iOS, NSImage on macOS.

// MARK: - PDF / EPUB utility namespaces
//
// PDFSelectionCoordinator     — `PDF/PDFSelectionCoordinator.swift`. Static helpers for the
//                                PDFView selection lifecycle.
// PDFOutlineExtractor         — `PDF/PDFOutlineExtractor.swift`. Reads a PDFDocument outline
//                                into a [PDFOutlineNode].
// PDFPositionEncoder          — `Model/PDFPositionEncoder.swift`. Encodes/decodes PDF positions
//                                to/from the JSON string stored in Position.locator.
// EPUBSelectionCoordinator    — `EPUB/EPUBSelectionCoordinator.swift`. Same role on the EPUB side.
// EPUBPreferencesBridge       — `EPUB/EPUBPreferencesBridge.swift`. Translates RishiReader
//                                preferences into Readium's EPUBPreferences.
// EPUBDecorationApplier       — `EPUB/EPUBDecorationApplier.swift`. Applies highlight
//                                decorations to a Readium navigator.
// EPUBSpreadResolver          — `EPUB/EPUBSpreadModifier.swift`. Picks single vs. double spread.

// MARK: - Caches and loaders
//
// PDFThumbnailCache           — `PDF/PDFThumbnailCache.swift`. Actor. Caches PDF page thumbnails.
// EPUBUnpackedCache           — `EPUB/EPUBUnpackedCache.swift`. Actor. Unzipped-EPUB cache so
//                                Readium can stream without re-unpacking each open.
// EPUBPublicationLoader       — `EPUB/EPUBPublicationLoader.swift`. Opens an EPUB into a
//                                Readium Publication.
// EPUBPublicationLoading      — `EPUB/EPUBPublicationLoader.swift`. Protocol seam for tests.
// EPUBPublicationLoaderError  — `EPUB/EPUBPublicationLoader.swift`. Loader error enum.
// BookPrewarmer               — `Prewarm/BookPrewarmer.swift`. Warms the caches above so the
//                                next book open is instant.
// PDFPageWarmCache            — `Prewarm/BookPrewarmer.swift`. Protocol the prewarmer fills.
// EPUBWarmCache               — `Prewarm/BookPrewarmer.swift`. Protocol the prewarmer fills.

// MARK: - Storage
//
// ReaderSettingsStore         — `Storage/ReaderSettingsStore.swift`. Protocol. Reads/writes
//                                theme + typography + spread mode.
// UserDefaultsReaderSettingsStore
//                             — `Storage/UserDefaultsReaderSettingsStore.swift`. The default
//                                implementation, backed by UserDefaults.
// SampleReaderInstaller       — `Storage/SampleReaderInstaller.swift`. Copies the bundled
//                                sample EPUB into Application Support on first run.

// MARK: - Test seam
//
// navBarVisibility            — `UI/ReaderChromeController.swift`. Free function used by tests
//                                to assert the chrome controller's visibility output.
// _readerChromeDefaultSleep   — `UI/ReaderChromeController.swift`. Default Task.sleep wrapper;
//                                tests inject a fake to skip the auto-hide delay.
