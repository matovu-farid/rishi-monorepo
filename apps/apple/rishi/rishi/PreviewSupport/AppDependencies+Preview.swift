import SwiftUI


struct PreviewPlaceholder: View {

    let title: String
    let subtitle: String
    let variant: String

    var body: some View {
        VStack(spacing: RishiSpacing.l) {
            VStack(spacing: RishiSpacing.s) {
                Text(title)
                    .font(RishiTypography.titleL)
                    .foregroundStyle(RishiColor.textPrimary)
                Text(variant)
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.accent)
            }
            Text(subtitle)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
            Text("Composition root required for live data.")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(RishiSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        
    }
}
