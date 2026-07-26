#if canImport(UIKit)
import SwiftUI
import UIKit

/// Pure resolver for the appropriate ``EPUBSpreadMode`` given the current
/// device + size-class combination, per EPUB-10:
///
///   - iPad in landscape (`horizontalSizeClass == .regular &&
///     verticalSizeClass == .compact`) → `.auto` (Readium produces a
///     2-page spread)
///   - iPad in portrait (`.regular / .regular`) → `.single`
///   - iPhone (any orientation, `.compact` horizontal) → `.single`
///   - Mac (`.mac` idiom) → `.single`
///
/// Lives in a static enum so the heuristic is trivially unit-testable
/// without spinning up a SwiftUI view tree.
public enum EPUBSpreadResolver {

    public static func mode(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        idiom: UIUserInterfaceIdiom
    ) -> EPUBSpreadMode {
        // Only iPad in landscape gets two-page spread. We require both
        // size classes (regular/compact) AND the iPad idiom — Mac
        // Catalyst can report regular/compact while still wanting a
        // single column.
        if idiom == .pad,
           horizontalSizeClass == .regular,
           verticalSizeClass == .compact {
            return .auto
        }
        // iPad portrait, iPhone (any orientation), Mac → single column.
        return .single
    }
}

public extension View {
    /// Resolves the EPUB spread mode for the current size class + device
    /// and invokes `apply` whenever it changes (and once on appear).
    /// Use on the EPUB reader screen so the navigator's spread
    /// preference tracks the device.
    func epubSpread(apply: @escaping (EPUBSpreadMode) -> Void) -> some View {
        modifier(EPUBSpreadModifier(apply: apply))
    }
}

private struct EPUBSpreadModifier: ViewModifier {
    let apply: (EPUBSpreadMode) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content
            .onAppear { send() }
            .onChange(of: horizontalSizeClass) { _, _ in send() }
            .onChange(of: verticalSizeClass) { _, _ in send() }
    }

    private func send() {
        let mode = EPUBSpreadResolver.mode(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            idiom: UIDevice.current.userInterfaceIdiom
        )
        apply(mode)
    }
}
#endif
