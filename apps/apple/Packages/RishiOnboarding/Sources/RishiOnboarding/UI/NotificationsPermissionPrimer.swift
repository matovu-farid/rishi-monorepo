import SwiftUI
import RishiUIKit

/// Pre-permission rationale shown BEFORE the system notifications dialog.
/// ONB-02. Needed for Phase-7 silent-push sync wake.
///
/// `onAllow` is wired (by 11-06) to call
/// `UNUserNotificationCenter.current().requestAuthorization(...)`.
struct NotificationsPermissionPrimer: View {
    public let onAllow: () -> Void
    public let onSkip: () -> Void

    public init(
        onAllow: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.onAllow = onAllow
        self.onSkip = onSkip
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .belowContent) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "bell.badge.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text("Keep your reading in sync")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Allow silent background notifications so your library, position, and highlights stay in sync between your iPhone, iPad, and Mac. We never send alerts you'll see — this is just for sync.")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            VStack(spacing: RishiSpacing.m) {
                Button(action: onAllow) {
                    Text("Allow notifications")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.accent)
                .accessibilityIdentifier("onboarding-notifs-allow")

                Button("Not now", action: onSkip)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("onboarding-notifs-skip")
            }
            .padding(.horizontal, RishiSpacing.l)
        }
    }
}

#Preview {
    NotificationsPermissionPrimer(onAllow: {}, onSkip: {})
}
