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
                .background(
                    Capsule().fill(RishiColor.surfaceElevated.opacity(0.85))
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(percent) percent")
        }
    }
}
