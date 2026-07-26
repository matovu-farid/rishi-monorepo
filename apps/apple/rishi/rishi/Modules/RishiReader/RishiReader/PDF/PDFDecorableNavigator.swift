#if canImport(UIKit)
import Foundation
import PDFKit
import ReadiumNavigator
import UIKit

/// Readium ``DecorableNavigator`` that paints decorations via a UIView overlay.
///
/// Attach a live ``PDFView`` / ``PDFDocumentView`` via ``attach(pdfView:)``
/// (or init). Each `apply(decorations:in:)` call replaces prior overlay
/// specs owned by that decoration group — other groups are left alone.
///
/// Visibility uses ``PDFDecorationOverlayView`` (same convert-and-fill
/// approach as ``PDFHighlightOverlay``). PDFKit ``PDFAnnotation`` rendering
/// is intentionally not used — it is unreliable with Readium's
/// `usePageViewController`.
///
/// The overlay is installed as a **sibling above** ``PDFView`` (not a
/// subview). Readium's paginated mode calls `usePageViewController(true)`
/// before `setupPDFView`; page-VC content views sit on top of PDFView
/// subviews and would hide a child overlay. Matching the old SwiftUI
/// ``PDFHighlightOverlay`` ZStack sibling works around that.
///
/// Readium assigns `pdfView.document` *after* ``setupPDFView``, so
/// ``apply`` may run with a nil document. Decorations are stashed per
/// group and painted once a document is available via ``attach(pdfView:)``,
/// PDFKit document/page notifications, or ``reapplyIfNeeded()``.
///
/// Callers must invoke from the main actor (PDFKit UI). The type is not
/// `@MainActor`-isolated so it can conform to nonisolated
/// ``DecorableNavigator`` under Swift 6. Overlay UI is held
/// `nonisolated(unsafe)` and touched only on the main actor.
public final class PDFDecorableNavigator: DecorableNavigator, @unchecked Sendable {

    public weak var pdfView: PDFView?

    /// Overlay installed above PDF content. Public for test seams.
    /// Held unsafe because ``DecorableNavigator`` cannot be `@MainActor`.
    nonisolated(unsafe) public private(set) var decorationOverlayView: PDFDecorationOverlayView?

    /// Specs keyed by decoration group — source of truth for drawing / tests.
    private var specsByGroup: [String: [PDFDecorationAnnotationSpec]] = [:]
    /// Last `apply` request per group — kept even when document is nil.
    private var pendingDecorationsByGroup: [String: [Decoration]] = [:]
    private var interactionObservers: [String: OnActivatedCallback] = [:]
    private var notificationObservers: [NSObjectProtocol] = []

    public init(pdfView: PDFView? = nil) {
        self.pdfView = pdfView
        if let pdfView {
            installOverlay(on: pdfView)
            registerPDFViewObservers(for: pdfView)
        }
    }

    deinit {
        removePDFViewObservers()
    }

    public func attach(pdfView: PDFView) {
        removePDFViewObservers()
        let previous = decorationOverlayView
        decorationOverlayView = nil
        previous?.removeFromSuperview()

        self.pdfView = pdfView
        installOverlay(on: pdfView)
        registerPDFViewObservers(for: pdfView)
        reapplyIfNeeded()
    }

    /// Paints any stashed decorations if `pdfView.document` is now set.
    /// Call when the PDF document becomes ready (e.g. after
    /// ``PDFNavigatorDelegate`` location changes).
    public func reapplyIfNeeded() {
        guard pdfView?.document != nil else { return }
        for (group, decorations) in pendingDecorationsByGroup {
            paint(decorations: decorations, in: group)
        }
        bringOverlayAbovePDFView()
        decorationOverlayView?.setNeedsDisplay()
    }

    public func apply(decorations: [Decoration], in group: String) {
        pendingDecorationsByGroup[group] = decorations
        guard pdfView?.document != nil else {
            // Document not ready yet (common during setupPDFView). Keep the
            // request; do NOT clear overlay / pending — ``reapplyIfNeeded``
            // or a later apply will paint.
            return
        }
        paint(decorations: decorations, in: group)
    }

    public func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
        style == .highlight || style == .underline
    }

    public func observeDecorationInteractions(
        inGroup group: String,
        onActivated: @escaping OnActivatedCallback
    ) {
        interactionObservers[group] = onActivated
    }

    /// Test seam: whether an interaction observer is registered for `group`.
    public func hasDecorationInteractionObserver(inGroup group: String) -> Bool {
        interactionObservers[group] != nil
    }

    /// Test seam: overlay specs currently stored for `group`.
    public func overlaySpecsForTesting(in group: String) -> [PDFDecorationAnnotationSpec] {
        specsByGroup[group] ?? []
    }

    // MARK: - Private

    private func paint(decorations: [Decoration], in group: String) {
        guard pdfView?.document != nil else { return }
        let specs = PDFDecorationAnnotator.specs(from: decorations, in: group)
        if specs.isEmpty {
            specsByGroup.removeValue(forKey: group)
        } else {
            specsByGroup[group] = specs
        }
        decorationOverlayView?.replaceSpecs(specsByGroup.values.flatMap { $0 })
        bringOverlayAbovePDFView()
    }

    /// Installs the overlay as a sibling of `pdfView` when possible.
    ///
    /// Must not be a PDFView subview under Readium paginated mode:
    /// `usePageViewController(true)` stacks page content above PDFView
    /// children, so a child overlay draws but stays invisible.
    private func installOverlay(on pdfView: PDFView) {
        let overlay = PDFDecorationOverlayView(frame: .zero)
        overlay.pdfView = pdfView

        if let container = pdfView.superview {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.insertSubview(overlay, aboveSubview: pdfView)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
            ])
        } else {
            // Fallback — Readium normally adds pdfView to its hierarchy
            // before setupPDFView / attach.
            overlay.frame = pdfView.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pdfView.addSubview(overlay)
        }

        decorationOverlayView = overlay
        overlay.replaceSpecs(specsByGroup.values.flatMap { $0 })
    }

    /// Keeps the sibling overlay above `pdfView` after page / document churn.
    private func bringOverlayAbovePDFView() {
        guard let overlay = decorationOverlayView,
              let pdfView,
              let container = pdfView.superview,
              overlay.superview === container
        else { return }
        container.bringSubviewToFront(overlay)
    }

    private func registerPDFViewObservers(for pdfView: PDFView) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .PDFViewPageChanged,
            .PDFViewScaleChanged,
            .PDFViewDocumentChanged,
        ]
        for name in names {
            let token = center.addObserver(
                forName: name,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                self?.reapplyIfNeeded()
            }
            notificationObservers.append(token)
        }
    }

    private func removePDFViewObservers() {
        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        notificationObservers.removeAll()
    }
}
#endif
