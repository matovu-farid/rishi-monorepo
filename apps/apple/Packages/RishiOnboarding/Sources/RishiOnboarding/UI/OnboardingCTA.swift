import SwiftUI

enum OnboardingCTAConfiguration {
    static let regularWidth: CGFloat = 400

    static func maxWidth(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? regularWidth : .infinity
    }
}

enum OnboardingContentConfiguration {
    static let regularWidth: CGFloat = 560

    static func maxWidth(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? regularWidth : .infinity
    }
}

private struct OnboardingCTAWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.frame(maxWidth: OnboardingCTAConfiguration.maxWidth(for: horizontalSizeClass))
    }
}

private struct OnboardingContentWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.frame(maxWidth: OnboardingContentConfiguration.maxWidth(for: horizontalSizeClass))
    }
}

extension View {
    func onboardingCTAWidth() -> some View {
        modifier(OnboardingCTAWidthModifier())
    }

    func onboardingContentWidth() -> some View {
        modifier(OnboardingContentWidthModifier())
    }
}
