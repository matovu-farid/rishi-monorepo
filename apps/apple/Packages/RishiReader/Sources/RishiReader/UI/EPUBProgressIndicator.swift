import SwiftUI
import RishiUIKit

/// Floating bottom progress chip: "37%" of total publication progression.
///
/// Hidden when progression is unavailable (e.g. before the first locator
/// is published by the navigator). Surfaces a single combined accessibility
/// label so VoiceOver speaks "37 percent" rather than reading the symbol.
public struct EPUBProgressIndicator: View {

    public let totalProgression: Double?

    public init(totalProgression: Double?) {
        self.totalProgression = totalProgression
    }

    public var body: some View {
        if let progression = totalProgression {
            let clamped = min(max(progression, 0), 1)
            let percent = Int(clamped * 100)
            Text("\(percent)%")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
                .padding(.horizontal, RishiSpacing.m)
                .padding(.vertical, RishiSpacing.s)
                .modifier(GlassChipBackground())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(percent) percent")
        }
    }
}

/// Capsule surface for the progress chip. iOS 26 gets a Liquid Glass effect;
/// iOS 18 falls back to the translucent elevated-surface fill.
private struct GlassChipBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(RishiColor.surfaceElevated.opacity(0.85)))
        }
    }
}

#Preview("Quarter through") {
    EPUBProgressIndicator(totalProgression: 0.25)
        .padding(RishiSpacing.l)
        .background(RishiColor.readerBackgroundLight)
}

#Preview("Nearly done") {
    EPUBProgressIndicator(totalProgression: 0.92)
        .padding(RishiSpacing.l)
        .background(RishiColor.readerBackgroundSepia)
}

#Preview("Just opened") {
    EPUBProgressIndicator(totalProgression: 0.0)
        .padding(RishiSpacing.l)
        .background(RishiColor.readerBackgroundDark)
}

#Preview("Unavailable") {
    EPUBProgressIndicator(totalProgression: nil)
        .padding(RishiSpacing.l)
        .background(RishiColor.readerBackgroundLight)
}
