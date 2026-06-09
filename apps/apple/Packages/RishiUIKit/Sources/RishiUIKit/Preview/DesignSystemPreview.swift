import SwiftUI

/// Renders every design token in a scrollable list for visual review.
/// Use during reviews, snapshot tests, and Xcode previews to confirm tokens
/// look correct across light/dark/Dynamic Type sizes.
public struct DesignSystemPreview: View {

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RishiSpacing.xl) {
                colorsSection
                typographySection
                spacingSection
                radiusSection
                motionSection
            }
            .padding(RishiSpacing.l)
        }
        .background(RishiColor.background)
    }

    // MARK: - Sections

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.m) {
            Text("Colors").font(RishiTypography.titleL).foregroundStyle(RishiColor.textPrimary)
            colorRow("background",      RishiColor.background)
            colorRow("surface",         RishiColor.surface)
            colorRow("surfaceElevated", RishiColor.surfaceElevated)
            colorRow("divider",         RishiColor.divider)
            colorRow("textPrimary",     RishiColor.textPrimary)
            colorRow("textSecondary",   RishiColor.textSecondary)
            colorRow("textMuted",       RishiColor.textMuted)
            colorRow("accent",          RishiColor.accent)
            colorRow("accentMuted",     RishiColor.accentMuted)
            colorRow("warning",         RishiColor.warning)
            colorRow("danger",          RishiColor.danger)
            colorRow("success",         RishiColor.success)
        }
    }

    private func colorRow(_ name: String, _ color: Color) -> some View {
        HStack(spacing: RishiSpacing.m) {
            RoundedRectangle(cornerRadius: RishiRadius.medium)
                .fill(color)
                .frame(width: 56, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: RishiRadius.medium)
                        .stroke(RishiColor.divider, lineWidth: 1)
                )
            Text(name)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
            Spacer()
        }
    }

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.s) {
            Text("Typography").font(RishiTypography.titleL).foregroundStyle(RishiColor.textPrimary)
            Text("titleXL — The quick brown fox").font(RishiTypography.titleXL)
            Text("titleL — The quick brown fox").font(RishiTypography.titleL)
            Text("titleM — The quick brown fox").font(RishiTypography.titleM)
            Text("body — The quick brown fox").font(RishiTypography.body)
            Text("bodyEmphasized — The quick brown fox").font(RishiTypography.bodyEmphasized)
            Text("caption — The quick brown fox").font(RishiTypography.caption)
            Text("code — let x = 42").font(RishiTypography.code)
        }
        .foregroundStyle(RishiColor.textPrimary)
    }

    private var spacingSection: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.s) {
            Text("Spacing").font(RishiTypography.titleL).foregroundStyle(RishiColor.textPrimary)
            spacingRow("xxs",  RishiSpacing.xxs)
            spacingRow("xs",   RishiSpacing.xs)
            spacingRow("s",    RishiSpacing.s)
            spacingRow("m",    RishiSpacing.m)
            spacingRow("l",    RishiSpacing.l)
            spacingRow("xl",   RishiSpacing.xl)
            spacingRow("xxl",  RishiSpacing.xxl)
            spacingRow("xxxl", RishiSpacing.xxxl)
        }
    }

    private func spacingRow(_ name: String, _ value: CGFloat) -> some View {
        HStack(spacing: RishiSpacing.m) {
            Text("\(name) (\(Int(value)))")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
                .frame(width: 96, alignment: .leading)
            Rectangle()
                .fill(RishiColor.accent)
                .frame(width: value, height: 16)
        }
    }

    private var radiusSection: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.s) {
            Text("Radius").font(RishiTypography.titleL).foregroundStyle(RishiColor.textPrimary)
            HStack(spacing: RishiSpacing.m) {
                radiusSwatch("small",  RishiRadius.small)
                radiusSwatch("medium", RishiRadius.medium)
                radiusSwatch("large",  RishiRadius.large)
                radiusSwatch("pill",   RishiRadius.pill)
            }
        }
    }

    private func radiusSwatch(_ name: String, _ radius: CGFloat) -> some View {
        VStack(spacing: RishiSpacing.xs) {
            RoundedRectangle(cornerRadius: min(radius, 32))
                .fill(RishiColor.accentMuted)
                .frame(width: 64, height: 40)
            Text(name).font(RishiTypography.caption).foregroundStyle(RishiColor.textSecondary)
        }
    }

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.s) {
            Text("Motion").font(RishiTypography.titleL).foregroundStyle(RishiColor.textPrimary)
            Text("fast .180s   standard .320s   slow .500s")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
        }
    }
}

#Preview("Design System") {
    DesignSystemPreview()
}

#Preview("Design System — Dark") {
    DesignSystemPreview()
        .preferredColorScheme(.dark)
}

#Preview("Design System — XXL Dynamic Type") {
    DesignSystemPreview()
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
