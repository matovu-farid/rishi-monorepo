import Foundation
import Observation
import SwiftUI
import os.signpost
#if canImport(UIKit)
import UIKit
#endif

/// Phase 19 Plan 19-08 (F-P2-04) — file-static signposter so Instruments
/// can plot chrome-toggle latency (tap → SwiftUI re-render with new bar
/// visibility) on the timeline. `toggle()` is hit on every reader tap, so
/// the interval is intentionally cheap: a single field flip plus the
/// auto-hide task arm. The recorded interval is what surfaces in
/// Time Profiler as "user tap → visible chrome update".
private let chromeSignposter = OSSignposter(
    subsystem: "org.fidexa.rishi",
    category: "chrome"
)

/// Phase 18 Plan 18-01 (F-P0-04) — pure mapping from chrome visibility
/// to the SwiftUI `Visibility` value passed into `.toolbar(_:for: .navigationBar)`.
///
/// Lives at the top of this file so ReaderScreen / PDFReaderScreen can
/// import the same symbol they already pull in for `ReaderChromeController`.
/// Kept as a free function (not a method on the controller) so it can be
/// invoked from a SwiftUI modifier-builder closure without dragging the
/// `@Observable` lifetime through the toolbar modifier — and tested without
/// constructing a controller.
@MainActor
public func navBarVisibility(forChromeVisible isVisible: Bool) -> Visibility {
    isVisible ? .visible : .hidden
}

/// Abstracts the OS-level accessibility flags the reader needs to read
/// (currently only "is VoiceOver running"). Lets tests inject a fake
/// without dragging UIKit into the controller's test suite.
@MainActor
public protocol AccessibilityProviding: AnyObject {
    var isVoiceOverRunning: Bool { get }
}

#if canImport(UIKit)
/// Production `AccessibilityProviding` backed by `UIAccessibility`.
@MainActor
public final class UIKitAccessibilityProvider: AccessibilityProviding {
    public init() {}
    public var isVoiceOverRunning: Bool { UIAccessibility.isVoiceOverRunning }
}
#endif

/// Default sleeper for the production controller — wraps `Task.sleep(for:)`
/// so the controller never imports anything platform-specific.
/// Marked `public` purely so it can serve as a default-argument value.
@Sendable
public func _readerChromeDefaultSleep(_ duration: Duration) async throws {
    try await Task.sleep(for: duration)
}

/// Drives the visibility of the reader's top + bottom chrome (toolbar +
/// page indicator) on a tap-to-toggle / auto-hide cadence — mirroring
/// the Apple Books pattern.
///
/// Lifecycle:
/// - `isVisible` starts `false` by default. Callers can opt into an initially
///   visible state. The initial state only arms an idle timer when an
///   `initialAutoHideDelay` is provided.
/// - A central tap calls `toggle()` — flips visibility and (when showing)
///   starts the configured idle timer that hides chrome again.
/// - Tapping a toolbar button calls `userActivity()` to reset the timer.
/// - Calling `hide()` cancels any in-flight auto-hide so the controller
///   never re-fires a stale dismissal.
/// - When VoiceOver is running, the auto-hide timer is suppressed so
///   assistive-tech users always have the chrome reachable.
///
/// The controller takes an injected `sleep` closure so tests can drive
/// the idle timer deterministically; production wires `Task.sleep(for:)`.
@MainActor
@Observable
public final class ReaderChromeController {

    /// True when the top + bottom chrome are presented to the user.
    public private(set) var isVisible: Bool

    private let accessibility: any AccessibilityProviding
    private let autoHideDelay: Duration
    private let initialAutoHideDelay: Duration?
    private let sleep: @Sendable (Duration) async throws -> Void
    private var hideTask: Task<Void, Never>?

    /// When true the chrome is pinned: it starts visible and never toggles,
    /// hides, or auto-hides. Used on Mac Catalyst, where the toolbar (back
    /// button, voice chat, etc.) is expected to stay visible at all times —
    /// unlike the immersive tap-to-toggle behavior on iOS.
    private let alwaysVisible: Bool

    public init(
        accessibility: any AccessibilityProviding,
        autoHideDelay: Duration = .seconds(4),
        initialAutoHideDelay: Duration? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = _readerChromeDefaultSleep,
        initiallyVisible: Bool = false,
        alwaysVisible: Bool = false
    ) {
        self.accessibility = accessibility
        self.autoHideDelay = autoHideDelay
        self.initialAutoHideDelay = initialAutoHideDelay
        self.sleep = sleep
        self.alwaysVisible = alwaysVisible
        self.isVisible = alwaysVisible || initiallyVisible
        if isVisible, let initialAutoHideDelay {
            scheduleAutoHide(using: initialAutoHideDelay)
        }
    }

    // No explicit `deinit` cancellation: the auto-hide Task captures
    // `[weak self]` so it self-extinguishes when the controller goes
    // away. Touching `hideTask` from a nonisolated deinit would violate
    // MainActor isolation under Swift 6 strict concurrency.

    /// Flip visibility. If becoming visible, (re)arm the auto-hide timer.
    /// If becoming hidden, cancel any pending dismissal.
    public func toggle() {
        // Pinned chrome (Mac Catalyst) never toggles — it stays visible.
        guard !alwaysVisible else { return }
        // Phase 19 Plan 19-08 (F-P2-04) — wrap the chrome-toggle hot path.
        // Pure additive; behavior unchanged. The interval bounds the
        // synchronous body — the auto-hide Task started by show() runs
        // outside the interval, which is the right boundary for Instruments
        // (the tap → re-render latency is what matters).
        let state = chromeSignposter.beginInterval("reader.chrome.toggle")
        defer { chromeSignposter.endInterval("reader.chrome.toggle", state) }
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Reveal the chrome and arm the auto-hide timer. If VoiceOver is
    /// running the timer is skipped so chrome stays reachable.
    public func show() {
        isVisible = true
        scheduleAutoHide(using: autoHideDelay)
    }

    /// Hide the chrome immediately and cancel any pending auto-hide.
    public func hide() {
        // Pinned chrome (Mac Catalyst) never hides.
        guard !alwaysVisible else { return }
        cancelAutoHide()
        isVisible = false
    }

    /// Reset the idle timer in response to user interaction with the
    /// chrome (e.g. tapping a toolbar button).
    public func userActivity() {
        guard isVisible else { return }
        scheduleAutoHide(using: autoHideDelay)
    }

    // MARK: - Internal

    private func scheduleAutoHide(using delay: Duration) {
        cancelAutoHide()
        // Pinned chrome (Mac Catalyst) never auto-hides.
        guard !alwaysVisible else { return }
        guard !accessibility.isVoiceOverRunning else { return }

        let sleep = self.sleep
        // KEEP: ReaderChromeController is @MainActor (writes @Observable
        // isVisible). Task inherits MainActor so the sleep + write happen on
        // main; sleep is non-blocking so there's no MainActor stall.
        hideTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                // Cancelled — leave isVisible alone.
                return
            }
            guard let self else { return }
            // Re-check on resume — `hide()` might have already run.
            if !Task.isCancelled {
                self.isVisible = false
            }
        }
    }

    private func cancelAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }
}
