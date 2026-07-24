# Onboarding and First-Book Prompt Design

## Goal

Keep the introductory onboarding gentle and pre-authentication. After it is
completed, the normal signed-out screen lets the user choose when to sign in.
Once authenticated, the library invites the user to add a first book without
duplicating the existing import pipeline.

## Behavior

The onboarding wizard contains the welcome, microphone, voice-language, and
reader-hint stages. It does not ask the user to sign in or choose a book. The
wizard completes before the signed-out auth surface is shown.

On the first authenticated library visit, after the initial library sync, the
app presents `SampleOrImportScreen` as a sheet when the library is empty. The
device-scoped `@AppStorage` flag is set when the user chooses sample, import,
or skip, so “Skip for now” permanently dismisses this invitation on that
device. A restored library with existing books does not receive the prompt.

Choosing “Use sample” invokes the existing sample installer. Choosing
“Import a book” dismisses the sheet and presents the library’s existing
document picker. Choosing “Skip for now” leaves the library unchanged.

The per-account free-trial explainer is requested only after this first-book
sheet has been dismissed. If import was chosen, it waits for the document
picker to close (including cancellation or failure), so two sheets never race
or cover one another.

## Import data flow

1. `LibraryTabView` lifts a picker binding into `LibraryRootView`.
2. `LibraryRootView` presents SwiftUI `.fileImporter` for EPUB and PDF files.
3. The selected URLs go to `LibraryViewModel.importPicked`.
4. `LibraryViewModel` delegates to the existing `ImportCoordinator` with the
   authenticated owner ID, refreshes the library, and reports outcomes.
5. Existing success navigation and import-error alert handling remain in the
   library layer.

No onboarding-specific importer or storage path is introduced. Import and
picker cancellation remain handled by the existing library behavior.

## Verification

Run the RishiOnboarding package tests and a full app build when the local
simulator and SwiftPM cache are available. Also run `git diff --check` and
verify that the first-book prompt does not install bundled books before the
user makes a choice.
