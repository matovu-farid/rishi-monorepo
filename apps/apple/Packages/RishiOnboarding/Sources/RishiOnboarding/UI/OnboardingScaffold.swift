import SwiftUI
import RishiUIKit

/// Layout mode for onboarding screens. iPhone/iPad keep the full-bleed layout;
/// Mac Catalyst constrains content to a centered column so the hero and primary
/// button do not stretch across a wide window.
public enum OnboardingLayoutMode: Equatable {
    case fullBleed
    case centeredColumn(maxWidth: CGFloat)

    /// Pure decision used by the scaffold. Kept free of `#if` so it is
    /// unit-testable in isolation (see `OnboardingLayoutModeTests`).
    public static func resolve(isMacCatalyst: Bool) -> OnboardingLayoutMode {
        isMacCatalyst ? .centeredColumn(maxWidth: 440) : .fullBleed
    }

    /// Mode for the current build environment. The compile-time check is
    /// isolated here so the rest of the layout stays testable.
    static var current: OnboardingLayoutMode {
        #if targetEnvironment(macCatalyst)
        return resolve(isMacCatalyst: true)
        #else
        return resolve(isMacCatalyst: false)
        #endif
    }
}

/// Where the action buttons sit in the full-bleed (iPhone) layout. Ignored in
/// the Mac centered-column layout, where actions always follow the hero.
public enum OnboardingActionPlacement {
    /// Hero centered between spacers, actions pinned to the bottom edge.
    case pinnedToBottom
    /// Hero and actions stacked together and centered in the window.
    case belowContent
}

/// Shared container for onboarding screens. Owns spacing, padding, frame, and
/// background for both the iPhone (full-bleed) and Mac (centered-column)
/// layouts. Screens supply a `hero` and an `actions` builder.
struct OnboardingScaffold<Hero: View, Actions: View>: View {
    let mode: OnboardingLayoutMode
    let actionPlacement: OnboardingActionPlacement
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var actions: () -> Actions

    init(
        mode: OnboardingLayoutMode = .current,
        actionPlacement: OnboardingActionPlacement,
        @ViewBuilder hero: @escaping () -> Hero,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.mode = mode
        self.actionPlacement = actionPlacement
        self.hero = hero
        self.actions = actions
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RishiColor.surfaceElevated.ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch mode {
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
