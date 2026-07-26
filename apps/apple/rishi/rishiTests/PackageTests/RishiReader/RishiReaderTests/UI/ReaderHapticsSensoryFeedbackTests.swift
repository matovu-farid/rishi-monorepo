@testable import rishi
import Testing
import Foundation




/// Phase 18 Plan 18-02 — F-P1-01.
///
/// The reader haptics surface is being migrated from imperative
/// `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` to the
/// native SwiftUI `.sensoryFeedback(_:trigger:)` view modifier. The test
/// path therefore asserts on the trigger-binding VALUE that the
/// `.sensoryFeedback` modifier observes (an `Int` counter on the
/// viewmodel) — not on recorded calls into a fake UIKit generator.
///
/// Behaviors covered:
///   1. `PDFReaderViewModel` exposes `currentPageIndex: Int`. Calling
///      `vm.advancePage()` increments it by exactly 1.
///   2. `PDFReaderViewModel` exposes `lastBoundaryHitTick: Int`. Calling
///      `vm.hitBoundary()` increments it by exactly 1.
///   3. `ReaderViewModel` mirrors the same two fields and mutators.
///   4. `ReaderHaptics` is either deleted OR reduced to a Sendable
///      value-types-only namespace with zero UIKit dependency. Modelled
///      as a compile-only construction site: a regression that
///      re-introduces `UIImpactFeedbackGenerator` /
///      `UINotificationFeedbackGenerator` will break the build of
///      `RishiReaderTests` on dev hosts (no UIKit).
@Suite("ReaderHapticsSensoryFeedback", .serialized)
struct ReaderHapticsSensoryFeedbackTests {

    @Test("PDFReaderViewModel.advancePage increments currentPageIndex by 1")
    @MainActor
    func pdfAdvancePage_incrementsCurrentPageIndex() {
        let book = Book(
            userId: UUID(),
            title: "Trigger",
            formatType: .pdf,
            fileURL: "x"
        )
        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: URL(fileURLWithPath: "/dev/null"),
            positionStore: InMemoryPositionStore()
        )
        let before = vm.currentPageIndex

        vm.advancePage()

        #expect(vm.currentPageIndex == before + 1)
    }

    @Test("PDFReaderViewModel.hitBoundary increments lastBoundaryHitTick by 1")
    @MainActor
    func pdfHitBoundary_incrementsBoundaryTick() {
        let book = Book(
            userId: UUID(),
            title: "Trigger",
            formatType: .pdf,
            fileURL: "x"
        )
        let vm = PDFReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: URL(fileURLWithPath: "/dev/null"),
            positionStore: InMemoryPositionStore()
        )
        let before = vm.lastBoundaryHitTick

        vm.hitBoundary()

        #expect(vm.lastBoundaryHitTick == before + 1)
    }

    @Test("ReaderViewModel.advancePage increments currentPageIndex by 1")
    @MainActor
    func epubAdvancePage_incrementsCurrentPageIndex() {
        let book = Book(
            userId: UUID(),
            title: "Trigger",
            formatType: .epub,
            fileURL: "x"
        )
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: URL(fileURLWithPath: "/dev/null"),
            positionStore: InMemoryPositionStore()
        )
        let before = vm.currentPageIndex

        vm.advancePage()

        #expect(vm.currentPageIndex == before + 1)
    }

    @Test("ReaderViewModel.hitBoundary increments lastBoundaryHitTick by 1")
    @MainActor
    func epubHitBoundary_incrementsBoundaryTick() {
        let book = Book(
            userId: UUID(),
            title: "Trigger",
            formatType: .epub,
            fileURL: "x"
        )
        let vm = ReaderViewModel(
            book: book,
            userId: UUID(),
            documentURL: URL(fileURLWithPath: "/dev/null"),
            positionStore: InMemoryPositionStore()
        )
        let before = vm.lastBoundaryHitTick

        vm.hitBoundary()

        #expect(vm.lastBoundaryHitTick == before + 1)
    }

    /// Compile-time + runtime guard that `ReaderHaptics` (if it still
    /// exists as a namespace) carries no UIKit dependency. The body
    /// constructs whatever the reduced surface is. A regression that
    /// re-introduces UIKit will fail at compile time of this target on
    /// the macOS dev host (no UIKit available there).
    @Test("ReaderHaptics module has no UIKit dependency")
    @MainActor
    func haptics_module_has_no_uikit_dependency() {
        // Reference the type metatype. Compiles only if `ReaderHaptics`
        // either survives as a Sendable value-type namespace (Option B)
        // or was deleted (Option A — this test then doesn't reference
        // the symbol and is dropped during the migration).
        let _: ReaderHaptics.Type = ReaderHaptics.self
    }
}
