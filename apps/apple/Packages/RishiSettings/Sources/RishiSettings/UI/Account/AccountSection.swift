import SwiftUI
import RishiUIKit
import RishiCore

/// SET-01 Account section. Shows the signed-in user's email + display name,
/// a Sign Out button, and a navigation row to the destructive
/// DeleteAccountFlow.
///
/// The section takes both callbacks (`onSignOut`, `onShowDeleteFlow`) so
/// the parent screen owns navigation + auth wiring; this view stays a pure
/// SwiftUI section with no `@Environment` reach-ins.
public struct AccountSection: View {

    public let user: User
    public let onSignOut: () async -> Void
    public let onShowDeleteFlow: () -> Void

    public init(
        user: User,
        onSignOut: @escaping () async -> Void,
        onShowDeleteFlow: @escaping () -> Void
    ) {
        self.user = user
        self.onSignOut = onSignOut
        self.onShowDeleteFlow = onShowDeleteFlow
    }

    public var body: some View {
        Section {
            HStack {
                Text("Email")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                Spacer()
                Text(user.email)
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("settings-account-email")
            }
            if let displayName = user.displayName, !displayName.isEmpty {
                HStack {
                    Text("Name")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textPrimary)
                    Spacer()
                    Text(displayName)
                        .font(RishiTypography.caption)
                        .foregroundStyle(RishiColor.textSecondary)
                        .accessibilityIdentifier("settings-account-name")
                }
            }
            Button("Sign Out") {
                Task { await onSignOut() }
            }
            .foregroundStyle(RishiColor.accent)
            .accessibilityIdentifier("settings-account-signout")

            Button("Delete Account…") {
                onShowDeleteFlow()
            }
            .foregroundStyle(RishiColor.danger)
            .accessibilityIdentifier("settings-account-delete")
        } header: {
            Text("Account")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview("With Name") {
    Form {
        AccountSection(
            user: User(
                email: "reader@example.com",
                displayName: "Sample Reader",
                hasPro: true
            ),
            onSignOut: {},
            onShowDeleteFlow: {}
        )
    }
}

#Preview("Email Only") {
    Form {
        AccountSection(
            user: User(email: "reader@example.com"),
            onSignOut: {},
            onShowDeleteFlow: {}
        )
    }
}
