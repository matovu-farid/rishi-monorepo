import Foundation

/// Pure business math for the Mac menu / keyboard font-step command.
///
/// Extracted from ``ReaderScreen`` (Plan 34-03, SRP): the screen used to
/// inline `ReaderFontSize.clamped(current + delta * pointsPerStep)` inside an
/// `.onReceive` handler. That math is a model-layer concern with a single,
/// deterministic reason to change (the step size), so it lives here as a
/// stateless, fully testable unit. The view-model / coordinator drives it; the
/// view no longer knows how a font step is computed.
///
/// `nonisolated` enum — pure data, no isolation needed; the test suite reads it
/// without an `await`.
public enum EPUBFontStepCalculator {

    /// Point delta applied per discrete font step. One Cmd-+ / Cmd-- press is a
    /// `delta` of +1 / -1; each step moves the body size by this many points.
    /// Mirrors the historical `delta * 2.0` constant from the screen.
    public static let pointsPerStep: Double = 2.0

    /// Returns the new font size after applying `delta` steps to `current`.
    ///
    /// - Parameters:
    ///   - current: the current body font size.
    ///   - delta: number of steps (positive = larger, negative = smaller).
    /// - Returns: the stepped, clamped size. Returns `current` unchanged when
    ///   `delta == 0` (a no-op press, e.g. a stray notification).
    public static func step(
        from current: ReaderFontSize,
        delta: Int
    ) -> ReaderFontSize {
        guard delta != 0 else { return current }
        return ReaderFontSize.clamped(current.points + Double(delta) * pointsPerStep)
    }
}
