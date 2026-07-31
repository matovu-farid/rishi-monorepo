> **Status:** Adversarial review loop complete — **PASS WITH NOTES** (2 rounds, 0 open Critical/High issues).

# Swift concurrency warning cleanup

## Scope

Remove the Swift 6 warnings shown in the Xcode issue navigator while preserving
the existing PDF/EPUB behavior and unrelated working-tree changes. The Xcode
recommended-settings notice is informational and will not be resolved by
hand-editing migration metadata.

## Implementation order

1. Isolate Readium/UIKit wrapper entry points on `MainActor` and keep the
   nonisolated PDF delegate boundary synchronous while reading UIKit state only
   inside `MainActor.assumeIsolated`.
2. Make PDFKit ownership explicit and keep `PDFDocument`/`PDFSelection` on the
   main actor; remove detached-task crossings that move non-Sendable PDFKit
   objects between executors.
3. Remove the redundant `await` from `BookUploader`.
4. Build the shared `rishi` scheme and inspect diagnostics for remaining
   warnings/errors.

## Consumer / call-site audit

| API | Consumers checked | Expected impact |
|---|---|---|
| `EPUBDecorationApplier.apply` | no production callers; tests use `groupName` | callers must already be main-actor UI code |
| `EPUBPreferencesBridge.apply` | `ReaderNavigatorCoordinator`, `ReaderScreen` | already main-actor isolated |
| `PDFReaderViewModel` | `ReaderViewModels+Make`, PDF reader screens, reader tests | preserve public behavior; update only compiler-required isolation at call sites |
| `PDFSearchModel` | `PDFReaderScreen` | already main-actor isolated |
| `BookFileStorage.absoluteFileURL` | `BookUploader` | synchronous call |

## Adversarial review loop

Each round: review → log findings → update the artifact → re-review.

### Round 1 — Research review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | Build-first check could not reach compilation because package resolution was blocked by sandbox network restrictions. | Request a network-enabled canonical build after implementation; do not claim compilation until exit 0 is observed. |
| 2 | High | `PDFDocument` and `PDFSelection` are non-Sendable and were being crossed through detached/notification closures. | Keep PDFKit objects on `MainActor`; explicitly annotate notification closure and remove detached PDFDocument return. |
| 3 | High | Readium UIKit methods were called from synchronous nonisolated wrappers. | Annotate only the wrapper methods that call UIKit APIs; preserve public pure translation helpers. |
| 4 | Medium | Xcode recommended-settings notice may tempt a broad project migration. | Leave migration metadata untouched unless Xcode produces a reviewed, necessary diff. |

**Round 1 result:** Re-review required after implementation.

### Round 2 — Implementation re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Synchronous PDF parsing on `MainActor` could freeze large-document cold opens. | Restored detached parsing with an explicit single-owner `PDFDocumentTransfer` boundary; the live document remains main-actor-owned after transfer. |
| 2 | High | Main-actor isolation changed PDF reader test call sites. | Annotated all affected reader test suites `@MainActor`; the reader test sources now compile past these actor errors. |
| 3 | Medium | The complete `rishiTests` target still reports unrelated pre-existing `EntitlementLevel` API errors in billing tests. | Out of scope for this warning cleanup; app-target build is independently green. |

**Round 2 result:** PASS WITH NOTES — 0 open Critical/High issues. The app target build exits 0; the full test target remains blocked by unrelated billing-test compilation errors.

### Out of scope

- staged hnswlib deletions, existing project-file edits, and existing
  `PDFDecorableNavigator` edits;
- replacing Readium/PDFKit/AVFoundation;
- broad Xcode project migration or warning suppression flags.
