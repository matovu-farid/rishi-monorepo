import SwiftUI

/// Layout mode for full-screen "hero + actions" screens (onboarding, sign-in,
/// empty states). iPhone/iPad keep the full-bleed layout; Mac Catalyst
/// constrains content to a centered column so the hero and primary button do
/// not stretch across a wide window.
public enum RishiScreenLayout: Equatable {
    case fullBleed
    case centeredColumn(maxWidth: CGFloat)

    /// Pure decision used by the scaffold. Kept free of `#if` so it is
    /// unit-testable in isolation (see `RishiScreenLayoutTests`).
    public static func resolve(isMacCatalyst: Bool) -> RishiScreenLayout {
        isMacCatalyst ? .centeredColumn(maxWidth: 440) : .fullBleed
    }

    /// Layout for the current build environment. The compile-time check is
    /// isolated here so the rest of the layout stays testable.
    public static var current: RishiScreenLayout {
        #if targetEnvironment(macCatalyst)
        return resolve(isMacCatalyst: true)
        #else
        return resolve(isMacCatalyst: false)
        #endif
    }
}

/// Where the action buttons sit in the full-bleed (iPhone) layout. Ignored in
/// the Mac centered-column layout, where actions always follow the hero.
public enum RishiScreenActionPlacement {
    /// Hero centered between spacers, actions pinned to the bottom edge.
    case pinnedToBottom
    /// Hero and actions stacked together and centered in the window.
    case belowContent
}

/// Shared container for full-screen "hero + actions" screens. Owns the vertical
/// arrangement, frame, and background for both the iPhone (full-bleed) and Mac
/// (centered-column) layouts. Callers supply a `hero` and an `actions` builder
/// and keep their own horizontal padding inside those builders.
public struct RishiScreenScaffold<Hero: View, Actions: View>: View {
    private let layout: RishiScreenLayout
    private let actionPlacement: RishiScreenActionPlacement
    @ViewBuilder private let hero: () -> Hero
    @ViewBuilder private let actions: () -> Actions

    public init(
        layout: RishiScreenLayout = .current,
        actionPlacement: RishiScreenActionPlacement,
        @ViewBuilder hero: @escaping () -> Hero,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.layout = layout
        self.actionPlacement = actionPlacement
        self.hero = hero
        self.actions = actions
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RishiColor.surfaceElevated.ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .centeredColumn(let maxWidth):
            VStack(spacing: RishiSpacing.xl) {
                hero()
                actions()
            }
            .frame(maxWidth: maxWidth)
            .padding(RishiSpacing.l)
        case .fullBleed:
            fullBleed
        }
    }

    @ViewBuilder private var fullBleed: some View {
        switch actionPlacement {
        case .pinnedToBottom:
            VStack(spacing: RishiSpacing.l) {
                Spacer(minLength: 0)
                hero()
                Spacer(minLength: 0)
                actions()
            }
        case .belowContent:
            VStack(spacing: RishiSpacing.l) {
                hero()
                actions()
            }
            .padding(RishiSpacing.l)
        }
    }
}
