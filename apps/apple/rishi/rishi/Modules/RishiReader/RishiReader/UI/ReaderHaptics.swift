import Foundation

/// Phase 18 Plan 18-02 — F-P1-01.
///
/// Empty namespace retained for source compatibility. Reader haptics
/// migrated off the imperative UIKit feedback-generator API onto the
/// native SwiftUI `.sensoryFeedback(_:trigger:)` view modifier. The
/// trigger surface lives on the reader viewmodels
/// (``ReaderViewModel.currentPageIndex``,
/// ``ReaderViewModel.lastBoundaryHitTick``,
/// ``PDFReaderViewModel.currentPageIndex``,
/// ``PDFReaderViewModel.lastBoundaryHitTick``) — the screens attach
/// `.sensoryFeedback(.impact(weight: .light), trigger:)` and
/// `.sensoryFeedback(.warning, trigger:)`.
///
/// This namespace carries zero UIKit dependency. DO NOT re-introduce
/// an engine protocol seam here — `.sensoryFeedback` is the surface.
public enum ReaderHaptics: Sendable {}
