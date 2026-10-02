#if canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import os.signpost
import ReadiumShared
import ReadiumNavigator

private let readerNavigatorSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "reader"
)

/// Constructs and owns the Readium visual navigator for a single
/// publication. The coordinator is the bridge between Readium's
/// delegate callbacks and our `ReaderViewModel`.
///
/// Lifecycle:
///   1. `ReaderView.makeUIViewController` creates the coordinator,
///      which lazily constructs the navigator from the VM's
///      `publication` + `latestLocator`.
///   2. The coordinator hands the navigator back to UIKit.
///   3. On every locator change, `navigator(_:locationDidChange:)`
///      forwards to `viewModel.didChangeLocation(_:)`.
///   4. When the user finishes a selection, Readium asks the delegate
///      whether to show its default menu
///      (`SelectableNavigatorDelegate.navigator(_:shouldShowMenuForSelection:)`).
///      We return `false` and forward the selection to the screen via
///      `onSelectionChange`, which presents our floating
///      ``EPUBHighlightContextMenu`` instead.
///
/// **Sendability:** `@MainActor` matches Readium's `EPUBNavigatorDelegate`
/// protocol declaration, so delegate methods don't need `nonisolated`.
@MainActor
public final class ReaderNavigatorCoordinator: NSObject {

    public let viewModel: ReaderViewModel
    public private(set) var navigator: (UIViewController & VisualNavigator)?

    /// True while a read-aloud session has an active spoken paragraph. It keeps
    /// the active decoration and follow logic in sync with the session. User
    /// navigation is detected separately from this state.
    public var isFollowingReadAloud = false
    private var readAloudFollowTask: Task<Void, Never>?
    private var readAloudFollowTaskID: UUID?
    private var readAloudFollowGeneration: UInt64 = 0
    private var pendingReadAloudFollowLocator: Locator?
    var readAloudFollowNavigationForTesting: (@MainActor (Locator) async -> Bool)?
    private var programmaticNavigationCallbacks = 0
    private var programmaticNavigationGeneration: UInt64 = 0
    private var pdfProgrammaticFollow: PDFProgrammaticFollow?
    private var explicitForward: ExplicitPageForward?
    private var lateExplicitForwardCallback: LateExplicitForwardCallback?
    private var hasReceivedInitialLocation = false

    private struct PDFProgrammaticFollow {
        let requestID: UUID
        let navigatorIdentity: ObjectIdentifier
        let targetHref: String
        let targetPage: Int
        let followGeneration: UInt64
        var callbackObserved: Bool
    }

    private struct ExplicitPageForward {
        let id: UUID
        let navigatorIdentity: ObjectIdentifier
        let originPage: Int
        var callbackObserved: Bool
    }

    private struct LateExplicitForwardCallback {
        let id: UUID
        let navigatorIdentity: ObjectIdentifier
        let targetPage: Int
    }

    static func shouldFollowPDFTarget(targetPage: Int?, visiblePage: Int?) -> Bool {
        guard let targetPage, let visiblePage else { return true }
        return targetPage != visiblePage
    }

    /// Forwarded to the screen so it can present the highlight context
    /// menu. The closure is also called with `nil` when the user clears
    /// the selection — readers should hide the menu in that case.
    ///
    /// Readium 3.9 does NOT expose a push-style `selectionDidChange`
    /// callback. We fire `onSelectionChange` from
    /// `navigator(_:shouldShowMenuForSelection:)` (the only delegate
    /// method that gets a fresh `Selection` payload). Returning `false`
    /// suppresses Readium's default `UIMenuController` so the floating
    /// menu owns the surface.
    public var onSelectionChange: (Selection?) -> Void = { _ in }

    /// Fired after Readium reports a committed page/location change. The
    /// screen uses this to reveal the reader chrome independently of TTS
    /// navigation classification.
    public var onPageLocationChange: () -> Void = {}

    /// Phase 21 — fired by the container-level `UITapGestureRecognizer`
    /// installed in ``ReaderView``. The screen uses it to drive the
    /// tap-region resolver (left edge -> previous, center -> chrome
    /// toggle, right edge -> next). `point` is in the container view's
    /// coordinate space.
    public var onTap: (CGPoint) -> Void = { _ in }

    /// Fired when a hardware right-arrow key (or the on-screen right edge
    /// chevron) requests a forward page turn. The screen routes this to
    /// `ReaderPageNavigator.goNext()`. Registered as a Readium key observer in
    /// ``makeNavigatorIfNeeded()`` via ``handleArrowKey(_:)``.
    public var onPageForward: () -> Void = {}

    /// Fired when a hardware left-arrow key (or the on-screen left edge
    /// chevron) requests a backward page turn. The screen routes this to
    /// `ReaderPageNavigator.goPrev()`. Registered as a Readium key observer in
    /// ``makeNavigatorIfNeeded()`` via ``handleArrowKey(_:)``.
    public var onPageBackward: () -> Void = {}

    /// Fired once after the navigator has attached to the visible reader
    /// container. A later initial-location callback may refine reader state,
    /// but it must not be the only readiness signal: Readium can omit that
    /// callback when a navigator is restored from an existing view hierarchy.
    public var onFirstContentReady: @MainActor () async -> Void = {}

    /// Dismisses a pending selection when Escape is pressed. Returns true
    /// when the callback consumed the key and false when it should pass on.
    public var onEscape: () -> Bool = { false }

    /// The focused Catalyst PDF presentation mode. EPUB ignores this value.
    public var pdfViewMode: PDFViewModeSetting = .continuous {
        didSet {
            guard oldValue != pdfViewMode else { return }
            #if targetEnvironment(macCatalyst)
            guard navigator != nil else { return }
            if isApplyingPDFViewMode {
                pendingPDFViewMode = pdfViewMode
                return
            }
            applyPDFViewMode()
            #endif
        }
    }

    /// PDF decoration sink — attached in ``setupPDFView`` and used by
    /// ``applyHighlights(_:)`` when the active navigator is PDF.
    private let pdfDecorable = PDFDecorableNavigator()
    private var pdfViewportFitTask: Task<Void, Never>?
    private var hasFittedPDFViewport = false
    private var lastFittedPDFViewportSize: CGSize?
    private var pdfFitCandidateSize: CGSize?
    private var pdfFitCandidatePasses = 0
    private var isApplyingPDFViewMode = false
    private var pendingPDFViewMode: PDFViewModeSetting?
    private var didReportFirstContentReady = false
    private var firstContentCallbackTask: Task<Void, Never>?

    public init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.currentVisibleLocatorProvider = { [weak self] in
            await self?.navigator?.firstVisibleElementLocator()
        }
    }

    /// Cancels the deferred first-content callback when UIKit dismantles the
    /// representable. The task captures only the callback value, not the
    /// coordinator, so it cannot retain the UIKit hierarchy.
    public func cancelPendingFirstContentCallback() {
        firstContentCallbackTask?.cancel()
        firstContentCallbackTask = nil
    }

    /// Records the reliable UIKit attachment boundary. This is called only
    /// after the navigator is a child of the visible SwiftUI container, so
    /// consumers can safely reveal reader-owned affordances even when Readium
    /// does not subsequently emit its initial `locationDidChange` callback.
    public func navigatorDidAttach() {
        reportFirstContentReadyIfNeeded()
    }

    private func reportFirstContentReadyIfNeeded() {
        guard !didReportFirstContentReady else { return }
        didReportFirstContentReady = true
        let callback = onFirstContentReady
        firstContentCallbackTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await callback()
        }
    }

    /// Selector wired by
    /// ``ReaderView/installContainerTapRecognizer(on:coordinator:)``.
    /// Forwards the tap location to ``onTap`` only when the recognizer
    /// reports `.ended`.
    @objc public func handleContainerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let view = recognizer.view else { return }
        onTap(recognizer.location(in: view))
    }

    /// Maps a Readium arrow key to the active reader's Catalyst behavior.
    /// Returns true when the event is consumed by Rishi.
    @discardableResult
    public func handleArrowKey(_ key: Key) -> Bool {
        let action = ReaderKeyboardNavigationPolicy.action(
            for: key,
            isPDF: navigator is PDFNavigatorViewController,
            pdfViewMode: pdfViewMode
        )
        switch action {
        case .pageForward:
            onPageForward()
            return true
        case .pageBackward:
            onPageBackward()
            return true
        case .scrollUp:
            scrollPDFVertically(direction: -1)
            return true
        case .scrollDown:
            scrollPDFVertically(direction: 1)
            return true
        case .consume:
            return true
        case .passThrough:
            return false
        }
    }

    /// Routes Escape through the screen-owned selection state.
    @discardableResult
    public func handleEscape() -> Bool {
        onEscape()
    }

    /// Moves a Continuous PDF by one viewport with a small overlap so the
    /// reader keeps visual context between key presses. Readium's navigator
    /// consumes unhandled key events while it is first responder, so this must
    /// be explicit rather than delegated to UIKit's responder chain.
    private func scrollPDFVertically(direction: CGFloat) {
        guard let pdfNavigator = navigator as? PDFNavigatorViewController,
              let scrollView = pdfNavigator.pdfView.flatMap({ firstScrollView(in: $0) })
                  ?? firstScrollView(in: pdfNavigator.view),
              scrollView.bounds.height > 0 else { return }

        let step = scrollView.bounds.height * 0.8
        let top = -scrollView.adjustedContentInset.top
        let bottom = max(
            top,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let targetY = min(
            max(scrollView.contentOffset.y + (direction * step), top),
            bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: targetY),
            animated: true
        )
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    /// Re-applies the supplied highlights as Readium decorations in the
    /// `"rishi-highlights"` group. Safe to call before the navigator is
    /// built — no-ops in that case (the screen re-applies after load).
    ///
    /// EPUB uses the navigator's built-in ``DecorableNavigator``; PDF uses
    /// ``pdfDecorable`` (attached in ``setupPDFView``). Both share
    /// ``ReaderHighlightDecorationBuilder``.
    public func applyHighlights(_ highlights: [Highlight]) {
        let decorations = ReaderHighlightDecorationBuilder.make(from: highlights)
        let group = ReaderHighlightDecorationBuilder.groupName
        if let epub = navigator as? EPUBNavigatorViewController {
            epub.apply(decorations: decorations, in: group)
        } else if navigator is PDFNavigatorViewController {
            pdfDecorable.apply(decorations: decorations, in: group)
        }
    }

    /// Live PDFKit selection used to enrich Readium locators with line
    /// rects before persisting an ``EPUBHighlightLocator``. `nil` when the
    /// active navigator is not PDF or nothing is selected.
    ///
    /// Prefer the live ``PDFNavigatorViewController``'s `pdfView` selection
    /// (authoritative under Readium); fall back to the attached decorable
    /// overlay's `pdfView` when needed.
    public var pdfKitSelectionForHighlightEnrichment: PDFSelection? {
        guard let pdfNav = navigator as? PDFNavigatorViewController else { return nil }
        return pdfNav.pdfView?.currentSelection ?? pdfDecorable.pdfView?.currentSelection
    }

    /// Converts a Readium selection into a persistable locator, attaching
    /// PDF line rects when the active navigator is PDF.
    public func highlightLocator(from selection: Selection) -> EPUBHighlightLocator? {
        var locator = selection.locator
        if let pdfSelection = pdfKitSelectionForHighlightEnrichment {
            let document = (navigator as? PDFNavigatorViewController)?.pdfView?.document
            locator = PDFSelectionLocatorEnricher.enriching(locator, with: pdfSelection, in: document)
        } else if let pdfNav = navigator as? PDFNavigatorViewController,
                  let pdfView = pdfNav.pdfView,
                  let page = pdfView.currentPage,
                  let frame = selection.frame {
            // PDFNavigatorViewController builds the Readium Selection from
            // the PDFView frame. PDFKit may clear currentSelection before
            // our menu callback runs, but this frame is still sufficient to
            // persist a paintable page-space rectangle.
            let pageRect = pdfView.convert(frame.insetBy(dx: 8, dy: 8), to: page)
            locator = PDFSelectionLocatorEnricher.enriching(locator, with: [pageRect])
        }
        return EPUBSelectionCoordinator.makeLocator(fromLocator: locator)
    }

    /// Marks `paragraph` as the active read-aloud passage by replacing the
    /// single decoration in the `"rishi-tts"` group. The locator is anchored
    /// to the current resource (`latestLocator`); no-ops until the navigator
    /// and a locator both exist.
    public func highlightReadAloudParagraph(
        _ paragraph: String,
        at locator: Locator? = nil
    ) {
        guard let locator = locator ?? viewModel.latestLocator else { return }
        let group = ReaderReadAloudDecorationBuilder.groupName

        if let nav = navigator as? EPUBNavigatorViewController {
            let decoration = ReaderReadAloudDecorationBuilder.decoration(
                forParagraph: paragraph,
                href: locator.href,
                mediaType: locator.mediaType
            )
            nav.apply(decorations: [decoration], in: group)
            return
        }

        guard navigator is PDFNavigatorViewController,
              let pdfView = (navigator as? PDFNavigatorViewController)?.pdfView,
              let document = pdfView.document,
              let pageNumber = locator.locations.page,
              pageNumber > 0,
              let page = document.page(at: pageNumber - 1),
              let selection = PDFReadAloudHighlighter.selection(
                  in: page,
                  paragraph: paragraph
              ) else {
            // A scanned PDF or a paragraph with no extractable geometry
            // cannot be painted; remove any stale active passage instead.
            pdfDecorable.apply(decorations: [], in: group)
            return
        }

        let locatorWithGeometry = PDFSelectionLocatorEnricher.enriching(
            locator,
            with: selection
        )
        pdfDecorable.apply(
            decorations: [ReaderReadAloudDecorationBuilder.decoration(for: locatorWithGeometry)],
            in: group
        )
    }

    /// Clears the active read-aloud passage decoration (called when TTS
    /// stops). No-ops before the navigator is built.
    public func clearReadAloudHighlight() {
        invalidateReadAloudFollow()
        programmaticNavigationCallbacks = 0
        pdfProgrammaticFollow = nil
        explicitForward = nil
        lateExplicitForwardCallback = nil
        let group = ReaderReadAloudDecorationBuilder.groupName
        if let decorable = navigator as? any DecorableNavigator {
            decorable.apply(decorations: [], in: group)
        } else if navigator is PDFNavigatorViewController {
            pdfDecorable.apply(decorations: [], in: group)
        }
    }

    /// Registers the next location callback generated by a Readium
    /// auto-follow. The visible-location callback does not preserve the
    /// text-highlight locator used for the jump, so this is intentionally a
    /// one-shot callback token rather than locator equality matching.
    public func registerProgrammaticNavigation() {
        programmaticNavigationGeneration &+= 1
        programmaticNavigationCallbacks = 1
    }

    private func registerPDFProgrammaticFollow(
        requestID: UUID,
        navigator: UIViewController & VisualNavigator,
        locator: Locator,
        followGeneration: UInt64
    ) {
        guard let page = locator.locations.page else { return }
        pdfProgrammaticFollow = PDFProgrammaticFollow(
            requestID: requestID,
            navigatorIdentity: ObjectIdentifier(navigator),
            targetHref: locator.href.string,
            targetPage: page,
            followGeneration: followGeneration,
            callbackObserved: false
        )
    }

    private func clearPDFProgrammaticFollow(requestID: UUID) {
        guard pdfProgrammaticFollow?.requestID == requestID else { return }
        pdfProgrammaticFollow = nil
    }

    private func invalidateReadAloudFollow() {
        readAloudFollowGeneration &+= 1
        pendingReadAloudFollowLocator = nil
        readAloudFollowTask?.cancel()
        readAloudFollowTask = nil
        readAloudFollowTaskID = nil
        pdfProgrammaticFollow = nil
    }

    /// Arms one deliberate local PDF Next-page turn. The observed callback is
    /// correlated to this navigator and the visible origin page; an arbitrary
    /// callback cannot consume the intent.
    @discardableResult
    public func registerExplicitPageForward(id: UUID, originPage: Int) -> Bool {
        guard let nav = navigator, nav is PDFNavigatorViewController else { return false }
        lateExplicitForwardCallback = nil
        explicitForward = ExplicitPageForward(
            id: id,
            navigatorIdentity: ObjectIdentifier(nav),
            originPage: originPage,
            callbackObserved: false
        )
        return true
    }

    /// Completes a registered Next-page turn. If Readium moved without
    /// notifying its delegate, synthesize the tagged model update once and
    /// retain a one-shot marker for a delayed duplicate callback.
    @discardableResult
    public func completeExplicitPageForward(
        id: UUID,
        didMove: Bool,
        finalLocation: Locator?
    ) -> Bool {
        guard let request = explicitForward,
              request.id == id,
              navigator.map(ObjectIdentifier.init) == request.navigatorIdentity
        else { return false }

        guard didMove,
              let finalLocation,
              let targetPage = finalLocation.locations.page,
              targetPage == request.originPage + 1 else {
            explicitForward = nil
            return false
        }
        if request.callbackObserved {
            explicitForward = nil
            return true
        }

        viewModel.didChangeLocation(
            finalLocation,
            isProgrammatic: false,
            explicitForwardID: id
        )
        lateExplicitForwardCallback = LateExplicitForwardCallback(
            id: id,
            navigatorIdentity: request.navigatorIdentity,
            targetPage: targetPage
        )
        explicitForward = nil
        return false
    }

    /// Follows the active read-aloud paragraph: navigates the viewport to the
    /// paragraph's locator so the page turns when the spoken paragraph has
    /// scrolled onto a later page. Uses the SAME text-anchored locator as the
    /// highlight (`ReaderReadAloudDecorationBuilder.locator`), so a locator on the
    /// current page is a no-op and one on the next page turns it. No-ops until
    /// the navigator and a base locator both exist.
    @discardableResult
    public func navigateToReadAloudParagraph(_ paragraph: String) async -> Bool {
        guard let nav = navigator,
              let base = viewModel.latestLocator else { return false }
        let locator = ReaderReadAloudDecorationBuilder.locator(
            forParagraph: paragraph,
            href: base.href,
            mediaType: base.mediaType
        )
        let requestID = UUID()
        if nav is PDFNavigatorViewController {
            registerPDFProgrammaticFollow(
                requestID: requestID,
                navigator: nav,
                locator: locator,
                followGeneration: readAloudFollowGeneration
            )
        } else {
            registerProgrammaticNavigation()
        }
        let programmaticGeneration = programmaticNavigationGeneration
        let didNavigate = await nav.go(to: locator, options: NavigatorGoOptions(animated: true))
        if !didNavigate {
            // A failed Readium jump cannot produce the callback represented by
            // this token. Do not let it suppress the next real user page turn.
            if nav is PDFNavigatorViewController {
                clearPDFProgrammaticFollow(requestID: requestID)
            } else if programmaticNavigationGeneration == programmaticGeneration {
                programmaticNavigationCallbacks = 0
            }
        } else if nav is PDFNavigatorViewController,
                  pdfProgrammaticFollow?.requestID == requestID,
                  pdfProgrammaticFollow?.callbackObserved == false {
            // A successful Readium jump may not emit a visible-location
            // callback. Never leave a token around to mask a later swipe.
            clearPDFProgrammaticFollow(requestID: requestID)
        }
        return didNavigate
    }

    /// Follows a live read-aloud locator without touching the visible
    /// paragraph highlight. Used while an utterance is in flight so the
    /// viewport can keep up with a paragraph that spans a page boundary.
    public func followReadAloudLocator(_ locator: Locator) {
        guard isFollowingReadAloud else { return }
        pendingReadAloudFollowLocator = locator
        guard readAloudFollowTask == nil else { return }

        let generation = readAloudFollowGeneration
        let taskID = UUID()
        readAloudFollowTaskID = taskID
        readAloudFollowTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.readAloudFollowTaskID == taskID {
                    self.readAloudFollowTask = nil
                    self.readAloudFollowTaskID = nil
                }
            }

            while !Task.isCancelled,
                  self.isFollowingReadAloud,
                  self.readAloudFollowGeneration == generation,
                  let target = self.pendingReadAloudFollowLocator {
                self.pendingReadAloudFollowLocator = nil
                guard let nav = self.navigator else {
                    guard let testNavigation = self.readAloudFollowNavigationForTesting else { return }
                    // Test navigation has no UIKit navigator identity; the
                    // coordinator instance is its stable identity.
                    let navigatorIdentity = ObjectIdentifier(self)
                    let isPDF = self.viewModel.book.formatType == .pdf
                        || self.viewModel.publication?.manifest.conforms(to: .pdf) == true
                    let visiblePage = self.viewModel.visibleNavigatorLocator?.locations.page
                    if isPDF, !Self.shouldFollowPDFTarget(
                        targetPage: target.locations.page,
                        visiblePage: visiblePage
                    ) { continue }
                    let didNavigate = await testNavigation(target)
                    guard !Task.isCancelled,
                          self.isFollowingReadAloud,
                          self.readAloudFollowGeneration == generation,
                          self.navigator == nil,
                          navigatorIdentity == ObjectIdentifier(self) else { return }
                    if !isPDF && !didNavigate {
                        self.programmaticNavigationCallbacks = 0
                    }
                    continue
                }
                let navigatorIdentity = ObjectIdentifier(nav)

                let isPDF = nav is PDFNavigatorViewController
                    || self.viewModel.book.formatType == .pdf
                    || self.viewModel.publication?.manifest.conforms(to: .pdf) == true
                if isPDF,
                   !Self.shouldFollowPDFTarget(
                    targetPage: target.locations.page,
                    visiblePage: (nav as? PDFNavigatorViewController)?.currentLocation?.locations.page
                        ?? self.viewModel.visibleNavigatorLocator?.locations.page
                   ) {
                    continue
                }

                let requestID = UUID()
                if isPDF {
                    self.registerPDFProgrammaticFollow(
                        requestID: requestID,
                        navigator: nav,
                        locator: target,
                        followGeneration: generation
                    )
                } else {
                    self.registerProgrammaticNavigation()
                }
                let didNavigate: Bool
                if let testNavigation = self.readAloudFollowNavigationForTesting {
                    didNavigate = await testNavigation(target)
                } else {
                    didNavigate = await nav.go(to: target, options: NavigatorGoOptions(animated: true))
                }

                guard !Task.isCancelled,
                      self.isFollowingReadAloud,
                      self.readAloudFollowGeneration == generation,
                      self.navigator.map(ObjectIdentifier.init) == navigatorIdentity
                else { return }

                if isPDF {
                    // Callback correlation is page/href/identity scoped. If
                    // Readium returned without a matching callback, retire
                    // the request before the next user navigation can arrive.
                    self.clearPDFProgrammaticFollow(requestID: requestID)
                } else if !didNavigate {
                    self.programmaticNavigationCallbacks = 0
                }
            }
        }
    }

    /// Translates our reader settings into Readium's `EPUBPreferences`
    /// and submits them to the navigator. Safe to call before the
    /// navigator is built — no-ops in that case; the screen re-applies
    /// after `load()` completes.
    public func applyPreferences(
        typography: ReaderTypography,
        theme: ReaderTheme,
        spread: EPUBSpreadMode
    ) {
        guard let nav = navigator else { return }
        if let epub = nav as? EPUBNavigatorViewController {
            EPUBPreferencesBridge.apply(
                typography: typography,
                theme: theme,
                spread: spread,
                to: epub
            )
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// Readium's default reflowable EPUB inset includes a 34pt top margin on
    /// compact screens, then takes the window's safe-area top as a minimum.
    /// The iOS reader already places the navigator below the persistent native
    /// toolbar, so applying that top inset again creates the visible gap
    /// between the toolbar and the first line of text. Keep the default
    /// bottom breathing room while removing only the duplicated top inset.
    public func navigatorContentInset(
        _ navigator: VisualNavigator
    ) -> UIEdgeInsets? {
        guard let navigator = navigator as? EPUBNavigatorViewController else {
            return nil
        }
        let defaultBottom: CGFloat =
            navigator.traitCollection.verticalSizeClass == .regular ? 62 : 34
        let safeAreaBottom = navigator.view.window?.safeAreaInsets.bottom ?? 0
        return UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: max(defaultBottom, safeAreaBottom),
            right: 0
        )
    }
    #endif

    /// Navigates to the destination encoded by the supplied TOC `Link`.
    /// Used by ``ReaderTOCView``'s onSelect callback. No-ops if the
    /// navigator hasn't been built yet.
    @discardableResult
    public func go(to link: ReadiumShared.Link) async -> Bool {
        guard let nav = navigator else { return false }
        return await nav.go(to: link, options: NavigatorGoOptions(animated: true))
    }

    /// Navigates to a precise `Locator` — used by the bookmark-list jump (and,
    /// later, the search-result jump). Mirrors ``go(to:)`` for a `Link` and the
    /// read-aloud follow (`navigateToReadAloudParagraph`), which both go through
    /// `nav.go(to:options:)`. No-ops if the navigator hasn't been built yet.
    @discardableResult
    public func go(to locator: ReadiumShared.Locator) async -> Bool {
        guard let nav = navigator else { return false }
        return await nav.go(to: locator, options: NavigatorGoOptions(animated: true))
    }

    /// Follows a controller-authored shared location without treating its
    /// Readium callback as a local page turn. Unlike bookmark/search jumps,
    /// this must not invoke the local user-navigation lifecycle.
    @discardableResult
    public func goToSharedPosition(_ locator: ReadiumShared.Locator) async -> Bool {
        guard let nav = navigator else { return false }
        let requestID = UUID()
        if nav is PDFNavigatorViewController {
            registerPDFProgrammaticFollow(
                requestID: requestID,
                navigator: nav,
                locator: locator,
                followGeneration: readAloudFollowGeneration
            )
        } else {
            registerProgrammaticNavigation()
        }
        let registration = programmaticNavigationGeneration
        let didNavigate = await nav.go(to: locator, options: NavigatorGoOptions(animated: false))
        // A rejected or callback-free jump must not suppress the next real
        // swipe. An unrelated newer registration owns its own callback token.
        if nav is PDFNavigatorViewController {
            clearPDFProgrammaticFollow(requestID: requestID)
        } else if programmaticNavigationGeneration == registration {
            programmaticNavigationCallbacks = 0
        }
        return didNavigate
    }

    /// Imperatively clears the live selection (used after a highlight
    /// is saved so the menu doesn't stay anchored to old text).
    public func clearSelection() {
        (navigator as? any SelectableNavigator)?.clearSelection()
    }

    /// Builds the navigator if not already built. Safe to call multiple
    /// times — second call is a no-op. Returns silently when the
    /// publication is not yet loaded; the caller (View.updateUIViewController)
    /// will retry on the next SwiftUI tick once `viewModel.publication`
    /// becomes non-nil.
    public func makeNavigatorIfNeeded() throws {
        if navigator != nil { return }
        guard let publication = viewModel.publication else {
            Log.reader.debug("ReaderNavigatorCoordinator: publication not yet loaded; deferring navigator build")
            return
        }
        let constructionState = readerNavigatorSignposter.beginInterval("reader.navigator.construct")
        defer {
            readerNavigatorSignposter.endInterval("reader.navigator.construct", constructionState)
        }
        let nav: UIViewController & VisualNavigator
        if publication.manifest.conforms(to: .pdf) {
            let pdf = try PDFNavigatorViewController(
                publication: publication,
                initialLocation: viewModel.latestLocator
            )
            pdf.delegate = self
            nav = pdf
        } else {
            let epub = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: viewModel.latestLocator
            )
            epub.delegate = self
            nav = epub
        }
        #if targetEnvironment(macCatalyst)
        // Hardware arrows drive the same page-turn seam as the on-screen
        // chevrons. Continuous PDFs consume horizontal arrows so PDFKit cannot
        // turn pages, while vertical arrows explicitly move its native scroller.
        _ = nav.addObserver(.key(.arrowRight) { [weak self] in
            self?.handleArrowKey(.arrowRight) ?? false
        })
        _ = nav.addObserver(.key(.arrowLeft) { [weak self] in
            self?.handleArrowKey(.arrowLeft) ?? false
        })
        _ = nav.addObserver(.key(.arrowUp) { [weak self] in
            self?.handleArrowKey(.arrowUp) ?? false
        })
        _ = nav.addObserver(.key(.arrowDown) { [weak self] in
            self?.handleArrowKey(.arrowDown) ?? false
        })
        _ = nav.addObserver(.key(.escape) { [weak self] in
            self?.handleEscape() ?? false
        })
        #endif
        self.navigator = nav
        #if targetEnvironment(macCatalyst)
        if publication.manifest.conforms(to: .pdf) {
            applyPDFViewMode(to: nav as? PDFNavigatorViewController)
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func applyPDFViewMode() {
        applyPDFViewMode(to: navigator as? PDFNavigatorViewController)
    }

    private func applyPDFViewMode(to pdfNavigator: PDFNavigatorViewController?) {
        guard let pdfNavigator else { return }
        isApplyingPDFViewMode = true
        pendingPDFViewMode = nil
        let preferences: PDFPreferences
        switch pdfViewMode {
        case .continuous, .automatic:
            preferences = PDFPreferences(
                fit: .width,
                scroll: true,
                scrollAxis: .vertical,
                spread: .never,
                visibleScrollbar: true
            )
        case .singlePage:
            preferences = PDFPreferences(
                fit: .page,
                scroll: false,
                spread: .never,
                visibleScrollbar: true
            )
        case .twoPage:
            preferences = PDFPreferences(
                fit: .page,
                offsetFirstPage: true,
                scroll: false,
                spread: .always,
                visibleScrollbar: true
            )
        }
        pdfNavigator.submitPreferences(preferences)
        hasFittedPDFViewport = false
        lastFittedPDFViewportSize = nil
        pdfFitCandidateSize = nil
        pdfFitCandidatePasses = 0
        schedulePDFViewportFit()
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// Recomputes the initial PDF fit after the Readium child view has been
    /// installed and laid out. Readium performs its first fit while creating
    /// the PDFView, which can happen before the SwiftUI container has its
    /// final bounds and leave the first page visibly zoomed in.
    private func schedulePDFViewportFit() {
        guard navigator is PDFNavigatorViewController, !hasFittedPDFViewport else { return }
        pdfViewportFitTask?.cancel()
        pdfViewportFitTask = Task { [weak self] in
            for _ in 0..<20 {
                guard !Task.isCancelled, let self else { return }
                if self.fitPDFViewportIfReady() { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    @discardableResult
    private func fitPDFViewportIfReady() -> Bool {
        guard !hasFittedPDFViewport,
              let pdfNavigator = navigator as? PDFNavigatorViewController,
              let pdfView = pdfNavigator.pdfView,
              pdfView.document != nil,
              pdfView.currentPage != nil,
              !pdfNavigator.settings.scroll,
              pdfNavigator.view.bounds.width > 1,
              pdfNavigator.view.bounds.height > 1 else {
            return false
        }

        pdfNavigator.view.layoutIfNeeded()
        pdfView.layoutIfNeeded()
        // Readium's fit helper is package-internal. The public PDFKit
        // equivalent is the scale that fits the current page in the live
        // viewport, which is the correct initial behavior for the unified
        // reader's paginated PDF presentation.
        let fitScale = pdfView.scaleFactorForSizeToFit
        guard fitScale.isFinite, fitScale > 0 else { return false }

        pdfView.minScaleFactor = fitScale
        pdfView.scaleFactor = fitScale
        hasFittedPDFViewport = true
        return true
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    /// Recomputes the initial PDF fit after the Readium child view has been
    /// installed and laid out. Readium can perform its first fit before the
    /// SwiftUI container has its final bounds on iOS.
    private func schedulePDFViewportFitForIOS() {
        guard navigator is PDFNavigatorViewController, !hasFittedPDFViewport else { return }
        pdfViewportFitTask?.cancel()
        pdfViewportFitTask = Task { [weak self] in
            for _ in 0..<20 {
                guard !Task.isCancelled, let self else { return }
                if self.fitPDFViewportIfReadyForIOS() { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    @discardableResult
    private func fitPDFViewportIfReadyForIOS() -> Bool {
        guard !hasFittedPDFViewport,
              let pdfNavigator = navigator as? PDFNavigatorViewController,
              let pdfView = pdfNavigator.pdfView,
              pdfView.document != nil,
              pdfView.currentPage != nil,
              !pdfNavigator.settings.scroll,
              pdfNavigator.view.bounds.width > 1,
              pdfNavigator.view.bounds.height > 1 else {
            return false
        }

        pdfNavigator.view.layoutIfNeeded()
        pdfView.layoutIfNeeded()
        let fitScale = pdfView.scaleFactorForSizeToFit
        guard fitScale.isFinite, fitScale > 0 else { return false }

        pdfView.minScaleFactor = fitScale
        pdfView.scaleFactor = fitScale
        hasFittedPDFViewport = true
        return true
    }
    #endif
}

extension ReaderNavigatorCoordinator: EPUBNavigatorDelegate {

    public func navigator(_ navigator: any Navigator, locationDidChange locator: Locator) {
        // Readium sets `pdfView.document` after `setupPDFView` (in `go`).
        // Highlights applied during setup are stashed; paint them now.
        if navigator is PDFNavigatorViewController {
            pdfDecorable.reapplyIfNeeded()
            #if !targetEnvironment(macCatalyst)
            schedulePDFViewportFitForIOS()
            #endif
        }
        handleLocationChange(locator, navigatorIdentity: ObjectIdentifier(navigator as AnyObject))
    }

    /// Forwards a navigator location change to the view model. Only callbacks
    /// matching a registered auto-follow locator are marked programmatic; an
    /// unmatched callback is a user page turn and reaches `onUserNavigation`.
    public func handleLocationChange(
        _ locator: Locator,
        navigatorIdentity callbackNavigatorIdentity: ObjectIdentifier? = nil
    ) {
        let isInitialLocation = !hasReceivedInitialLocation
        hasReceivedInitialLocation = true
        var explicitForwardID: UUID?
        let pdfPage = locator.locations.page
        let callbackNavigatorIdentity = callbackNavigatorIdentity
            ?? navigator.map(ObjectIdentifier.init)
        let isPDFCallback = callbackNavigatorIdentity != nil
            && viewModel.publication?.manifest.conforms(to: .pdf) == true

        var isProgrammatic = false
        let tokenBefore = programmaticNavigationCallbacks
        if isPDFCallback {
            if let late = lateExplicitForwardCallback {
                if late.navigatorIdentity == callbackNavigatorIdentity,
                   late.targetPage == pdfPage {
                    lateExplicitForwardCallback = nil
                    Log.event("reader.nav.explicit.late_callback", data: ["id": late.id.uuidString])
                    return
                }
                lateExplicitForwardCallback = nil
            }

            if let follow = pdfProgrammaticFollow {
                let matches = follow.navigatorIdentity == callbackNavigatorIdentity
                    && follow.targetPage == pdfPage
                    && follow.targetHref == locator.href.string
                if matches {
                    isProgrammatic = true
                    pdfProgrammaticFollow = nil
                } else {
                    // An unrelated visible turn must never be consumed by a
                    // stale PDF auto-follow request.
                    pdfProgrammaticFollow = nil
                }
            }

            if let forward = explicitForward,
               forward.navigatorIdentity == callbackNavigatorIdentity,
               let page = pdfPage,
               page == forward.originPage + 1 {
                explicitForwardID = forward.id
                explicitForward?.callbackObserved = true
                explicitForward = nil
            } else if explicitForward != nil {
                explicitForward = nil
            }
        } else {
            isProgrammatic = programmaticNavigationCallbacks > 0
            if isProgrammatic {
                programmaticNavigationCallbacks -= 1
            }
        }
        Log.event("tts.nav.location", data: [
            "isProgrammatic": isProgrammatic ? "1" : "0",
            "tokenBefore": String(tokenBefore),
            "href": locator.href.string,
            "prog": locator.locations.progression.map { String(format: "%.4f", $0) } ?? "",
        ])
        if !isProgrammatic {
            if !isInitialLocation {
                onPageLocationChange()
            }
            // Native swipes and scrolls do not pass through the screen's
            // explicit page-turn actions, so clear any stale text selection
            // before the menu can remain anchored to the old location.
            onSelectionChange(nil)
        }
        viewModel.didChangeLocation(
            locator,
            isProgrammatic: isProgrammatic,
            isInitialLocation: isInitialLocation,
            explicitForwardID: explicitForwardID
        )
        if isInitialLocation {
            reportFirstContentReadyIfNeeded()
        }
    }

    public func navigator(_ navigator: any Navigator, presentExternalURL url: URL) {
        // Phase-6 v1: log + ignore. Open-in-Safari behavior is a later concern.
        Log.reader.debug("EPUB external URL tap: \(url.absoluteString, privacy: .public)")
    }

    public func navigator(_ navigator: any Navigator, presentError error: NavigatorError) {
        Log.reader.error("EPUB navigator error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - SelectableNavigatorDelegate

    /// Suppress Readium's default selection menu and forward the
    /// selection to the screen so it can present
    /// ``EPUBHighlightContextMenu``. `EPUBNavigatorDelegate` already
    /// inherits `SelectableNavigatorDelegate`, so no extra conformance
    /// is needed.
    public func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        onSelectionChange(selection)
        return false
    }
}

@MainActor
extension ReaderNavigatorCoordinator: PDFNavigatorDelegate {
    public nonisolated func navigator(
        _ navigator: PDFNavigatorViewController,
        setupPDFView view: PDFDocumentView
    ) {
        // Readium invokes setup on the main thread after the PDF view is
        // created; assumeIsolated matches other PDF callbacks in this package.
        MainActor.assumeIsolated {
            hasFittedPDFViewport = false
            pdfDecorable.attach(pdfView: view)
            applyHighlights(viewModel.loadedHighlights)
            // Document is often still nil here; locationDidChange / a later
            // apply with document present will flush via reapplyIfNeeded.
            pdfDecorable.reapplyIfNeeded()
            #if !targetEnvironment(macCatalyst)
            schedulePDFViewportFitForIOS()
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    public nonisolated func navigator(
        _ navigator: any ViewportObservingNavigator,
        viewportDidChange viewport: NavigatorViewport?
    ) {
        guard let pdfNavigator = navigator as? PDFNavigatorViewController else { return }
        MainActor.assumeIsolated {
            let viewportSize = pdfNavigator.view.bounds.size
            guard viewportSize != lastFittedPDFViewportSize else { return }
            hasFittedPDFViewport = false
            pdfFitCandidateSize = nil
            pdfFitCandidatePasses = 0
            schedulePDFViewportFit()
        }
    }
    #endif
}

extension ReaderNavigatorCoordinator: UIGestureRecognizerDelegate {

    /// Allow the container-level `UITapGestureRecognizer` to coexist
    /// with Readium's internal pan / tap / long-press recognizers.
    /// Without this, UIKit's recognition arbitration may delay or cancel
    /// the engine's pan recognizer while the tap is pending, which
    /// reproduces the "can't swipe to next page" symptom users hit
    /// before Phase 21.
    public nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
