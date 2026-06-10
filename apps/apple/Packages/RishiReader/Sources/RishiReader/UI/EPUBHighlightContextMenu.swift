#if canImport(UIKit)
import SwiftUI
import UIKit
import RishiCore
import RishiUIKit

/// Floating context menu shown above a Readium selection. Wraps the
/// shared ``HighlightContextMenu`` (Phase 5) with positioning logic
/// that places the menu above the selection's bounding rect.
///
/// Layout:
///   - If `selectionFrame` is supplied, anchor 48pt above the top edge
///     (clamped to >= 60pt from the top of the screen so the menu stays
///     visible under the toolbar).
///   - Otherwise center it on the visible window — used as a fallback
///     for selections Readium reports without a frame (rare).
///
/// All colors / spacings route through RishiUIKit tokens via the
/// underlying ``HighlightContextMenu``.
public struct EPUBHighlightContextMenu: View {

    public let selectionFrame: CGRect?
    public let onColor: (HighlightColor) -> Void
    public let onAddNote: () -> Void
    public let onDismiss: () -> Void

    public init(
        selectionFrame: CGRect?,
        onColor: @escaping (HighlightColor) -> Void,
        onAddNote: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.selectionFrame = selectionFrame
        self.onColor = onColor
        self.onAddNote = onAddNote
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GeometryReader { proxy in
            HighlightContextMenu(
                onColor: onColor,
                onAddNote: onAddNote,
                onDelete: nil // brand-new selection — delete only meaningful for existing rows
            )
            .position(menuCenter(in: proxy.size))
            .contentShape(Rectangle())
            .onTapGesture { /* swallow taps so background dismiss only fires elsewhere */ }
        }
        .background(
            // Background dim catcher that triggers dismissal when the
            // user taps anywhere outside the menu.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
                .allowsHitTesting(true)
        )
    }

    private func menuCenter(in containerSize: CGSize) -> CGPoint {
        guard let frame = selectionFrame else {
            return CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        }
        let x = frame.midX
        let y = max(frame.minY - 48, 60)
        return CGPoint(x: x, y: y)
    }
}
#endif
