// RishiReader — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiReader exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiReader is the unified reader. The active unified reader is backed
// by Readium; the package also retains the legacy PDF surface. It owns the SwiftUI screens,
// the view models, theme/typography settings, highlight overlays,
// and the prewarm cache that hides cold-open latency.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 2 unused exports).

// MARK: - Views (EPUB)
//
// ReaderScreen            — `UI/ReaderScreen.swift`. Full-screen unified reader (toolbar
//                                + ReaderView + sheets).
// ReaderView              — `EPUB/ReaderView.swift`. UIViewControllerRepresentable
//                                wrapping the Readium navigator.
// ReaderTOCView                 — `UI/ReaderTOCView.swift`. Table-of-contents sheet for EPUB.
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
// ReaderViewModel         — `EPUB/ReaderViewModel.swift`. @unchecked Sendable. Unified reader state
//                                + actions for ReaderScreen (position, highlights, sheet).
// PDFReaderViewModel          — `PDF/PDFReaderViewModel.swift`. @unchecked Sendable. State
//                                + actions for PDFReaderScreen.

// MARK: - Coordinators / Flows
//
// ReaderNavigatorCoordinator    — `EPUB/ReaderNavigatorCoordinator.swift`. NSObject. Glue between
//                                ReaderView and Readium delegates.
// ReaderCoordinatorRef          — `EPUB/ReaderView.swift`. Reference-cell that lets the
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
// ReaderPositionLocator       — `Model/ReaderPositionLocator.swift`. JSON-encodable Readium
//                                position used by both EPUB and PDF PositionStore rows.
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
// EPUBDecorationApplier       — `EPUB/EPUBDecorationApplier.swift`. Thin EPUB wrapper around
//                                ReaderHighlightDecorationBuilder.
// ReaderHighlightDecorationBuilder — `Model/ReaderHighlightDecorationBuilder.swift`. Shared
//                                Highlight → [Decoration] mapping for EPUB + PDF.
// PDFDecorableNavigator       — `PDF/PDFDecorableNavigator.swift`. DecorableNavigator that
//                                paints Readium decorations via PDFDecorationOverlayView.
// PDFDecorationOverlayView    — `PDF/PDFDecorationOverlayView.swift`. UIView overlay that
//                                converts page-space rects and fills highlight tints.
// PDFDecorationAnnotator      — `PDF/PDFDecorationAnnotator.swift`. Pure planner from
//                                Decoration → PDF annotation specs (page, bounds, tint tags).
// PDFSelectionLocatorEnricher — `PDF/PDFSelectionLocatorEnricher.swift`. Attaches PDFKit
//                                line rects onto a Readium Locator for unified PDF highlights.
// EPUBSpreadResolver          — `EPUB/EPUBSpreadModifier.swift`. Picks single vs. double spread.

// MARK: - Caches and loaders
//
// PDFThumbnailCache           — `PDF/PDFThumbnailCache.swift`. Actor. Caches PDF page thumbnails.
// EPUBUnpackedCache           — `EPUB/EPUBUnpackedCache.swift`. Actor. Unzipped-EPUB cache so
//                                Readium can stream without re-unpacking each open.
// PublicationLoader       — `EPUB/PublicationLoader.swift`. Opens an EPUB into a
//                                Readium Publication.
// PublicationLoading      — `EPUB/PublicationLoader.swift`. Protocol seam for tests.
// PublicationLoaderError  — `EPUB/PublicationLoader.swift`. Loader error enum.
// BookPrewarmer               — `Prewarm/BookPrewarmer.swift`. Warms the caches above so the
//                                next book open is instant.
// PDFPageWarmCache            — `Prewarm/BookPrewarmer.swift`. Protocol the prewarmer fills.
// EPUBWarmCache               — `Prewarm/BookPrewarmer.swift`. Protocol the prewarmer fills.

// MARK: - Text to speech
//
// CustomTTSTokenizer          — `EPUB/CustomTTSTokenizer.swift`. Readium content tokenizer
//                                that emits paragraph-sized utterances.

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
