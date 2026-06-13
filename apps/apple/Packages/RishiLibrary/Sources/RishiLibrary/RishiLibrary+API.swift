// RishiLibrary — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiLibrary exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiLibrary owns the library home screen, book file storage on
// disk, and the import pipeline (document picker -> extract
// metadata + cover -> save to BookStore). It depends on RishiCore
// (Book model, BookStore protocol) and RishiUIKit (tokens), not on
// RishiDB directly.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 10 unused exports).

// MARK: - Views
//
// LibraryRootView             — `Views/LibraryRootView.swift`. The library home screen.
//                                Renders the cover grid + Reading Now shelf + search field.
// DocumentPickerView          — `Import/DocumentPickerView.swift`. SwiftUI wrapper around
//                                UIDocumentPickerViewController for .epub / .pdf import.

// MARK: - Services
//
// BookFileStorage             — `Storage/BookFileStorage.swift`. Actor. Copies imported
//                                files into Application Support, returns canonical file URLs,
//                                deletes on book removal.
// BookFileStorage.StorageError — `Storage/BookFileStorage.swift`. Errors thrown by the actor.
// CoverCache                  — `Storage/CoverCache.swift`. Actor. Disk + memory cache for
//                                extracted cover images keyed by BookID.
// ImportCoordinator           — `Import/ImportCoordinator.swift`. Actor. Runs the
//                                pick -> validate -> extract -> persist pipeline. Returns
//                                ImportOutcome telling the UI what happened.
// ImportCoordinator.ImportOutcome
//                             — `Import/ImportCoordinator.swift`. Enum: imported / skipped /
//                                failed (with reason).

// MARK: - Extractors
//
// EpubCoverExtractor          — `Storage/EpubCoverExtractor.swift`. CoverExtractor for EPUB.
// EpubMetadataExtractor       — `Storage/EpubMetadataExtractor.swift`. MetadataExtractor for EPUB.
// PDFKitCoverExtractor        — `Storage/PDFKitCoverExtractor.swift`. CoverExtractor for PDF.
// PDFKitMetadataExtractor     — `Storage/PDFKitMetadataExtractor.swift`. MetadataExtractor for PDF.

// MARK: - Models / Types
//
// ReadingNowEntry             — `Models/ReadingNowEntry.swift`. The Reading-Now shelf row
//                                (book + percent-read + last-opened-at).

// MARK: - Kept public on purpose
//
// (Types that LOOK like they could be internal but were deliberately
// kept public during the 2026-06-13 surface audit. See commit 3d030c8bc.)
//
// MetadataExtractor           — public protocol so tests can inject a fake metadata extractor
//                                into ImportCoordinator without touching real EPUB/PDF files.
// CoverExtractor              — same rationale as MetadataExtractor; protocol seam for tests.
// BookMetadata                — kept public because it is the return type of MetadataExtractor.
// ReadingNowEntry             — referenced from the app target (LibraryRootView consumes a
//                                [ReadingNowEntry] passed in by the parent).
