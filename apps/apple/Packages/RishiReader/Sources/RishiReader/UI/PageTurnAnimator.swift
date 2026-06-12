import SwiftUI

/// SwiftUI container that wraps page content with the Apple-Books-style
/// horizontal slide, drag-to-track interaction, rubber-band boundaries,
/// and reduce-motion cross-fade fallback.
///
/// **Usage**
/// ```swift
/// PageTurnAnimator(
///     pageIndex: viewModel.pageIndex,
///     totalPages: viewModel.totalPages,
///     onCommitNext:     { viewModel.goNext() },
///     onCommitPrevious: { viewModel.goPrevious() },
///     onBoundary:       { /* optional */ }
/// ) {
///     CurrentPageView(viewModel: viewModel)
/// }
/// ```
///
/// The wrapped content view should redraw whenever `pageIndex` changes;
/// SwiftUI uses `.id(pageIndex)` to swap-in the new page so the transition
/// fires.
///
/// **Why not wire this into the live EPUB / PDF readers right now?**
/// Both shipping reader views delegate paging to a UIKit engine
/// (`EPUBNavigatorViewController` and `PDFView.usePageViewController(true)`)
/// that owns its own internal scroller — a SwiftUI `.transition` cannot
/// reach those engines without replacing them. This container is
/// therefore the foundation; wiring it requires a separate plan that
/// swaps the underlying paginator for a SwiftUI-driven one. See the
/// follow-ups in the implementation report.
@MainActor
public struct PageTurnAnimator<Content: View>: View {

    private let pageIndex: Int
    private let totalPages: Int
    private let onCommitNext: () -> Void
    private let onCommitPrevious: () -> Void
    private let onBoundary: () -> Void
    private let onPageTurn: () -> Void
    private let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    /// Tracks the direction of the last committed page turn so the
    /// `.id`-based transition knows whether to slide in from leading or
    /// trailing.
    @State private var lastDirectionForward: Bool = true

    public init(
        pageIndex: Int,
        totalPages: Int,
        onCommitNext: @escaping () -> Void,
        onCommitPrevious: @escaping () -> Void,
        onBoundary: @escaping () -> Void = {},
        onPageTurn: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.pageIndex = pageIndex
        self.totalPages = totalPages
        self.onCommitNext = onCommitNext
        self.onCommitPrevious = onCommitPrevious
        self.onBoundary = onBoundary
        self.onPageTurn = onPageTurn
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let pageWidth = proxy.size.width
            let resolver = PageTurnGestureResolver(pageWidth: pageWidth)
            let transitionResolver = ReaderPageTransitionResolver()
            let isAtLeading  = pageIndex <= 0
            let isAtTrailing = pageIndex >= max(totalPages - 1, 0)

            ZStack {
                content()
                    .frame(width: pageWidth, height: proxy.size.height)
                    .id(pageIndex)
                    .transition(
                        transition(
                            for: transitionResolver.style(
                                forward: lastDirectionForward,
                                reduceMotion: reduceMotion
                            )
                        )
                    )
                    .offset(x: dragOffset)
                    .shadow(
                        color: Color.black.opacity(shadowOpacity(width: pageWidth)),
                        radius: 8,
                        x: dragOffset < 0 ? -4 : (dragOffset > 0 ? 4 : 0),
                        y: 0
                    )
            }
            .frame(width: pageWidth, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let damped = resolver.rubberBandedTranslation(
                            raw: value.translation.width,
                            isAtLeadingBoundary: isAtLeading,
                            isAtTrailingBoundary: isAtTrailing
                        )
                        dragOffset = damped
                    }
                    .onEnded { value in
                        let decision = resolver.decide(
                            translation: value.translation.width,
                            velocity: value.predictedEndTranslation.width
                                - value.translation.width,
                            isAtLeadingBoundary: isAtLeading,
                            isAtTrailingBoundary: isAtTrailing
                        )
                        commit(decision: decision, reduceMotion: reduceMotion)
                    }
            )
        }
    }

    // MARK: - Commit

    private func commit(decision: PageTurnGestureResolver.Decision, reduceMotion: Bool) {
        switch decision {
        case .commitNext:
            lastDirectionForward = true
            withAnimation(commitAnimation(reduceMotion: reduceMotion)) {
                dragOffset = 0
            }
            onPageTurn()
            onCommitNext()
        case .commitPrevious:
            lastDirectionForward = false
            withAnimation(commitAnimation(reduceMotion: reduceMotion)) {
                dragOffset = 0
            }
            onPageTurn()
            onCommitPrevious()
        case .snapBack:
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                dragOffset = 0
            }
        case .boundaryBounce:
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                dragOffset = 0
            }
            onBoundary()
        }
    }

    private func commitAnimation(reduceMotion: Bool) -> Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.18)
        }
        return .interactiveSpring(response: 0.32, dampingFraction: 0.86)
    }

    private func shadowOpacity(width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        // Up to ~30% shadow when the page is dragged a full width.
        return min(0.30, Double(abs(dragOffset) / width) * 0.5)
    }

    private func transition(for style: ReaderPageTransitionResolver.Style) -> AnyTransition {
        switch style {
        case .slideForward:
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .slideBackward:
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )
        case .crossFade:
            return .opacity
        }
    }
}
