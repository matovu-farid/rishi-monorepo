import SwiftUI
import RishiUIKit
import RishiCore

/// SET-01 Account section. Shows the signed-in user's email,
/// a Sign Out button, and a destructive "Delete Account" row. Tapping the row
/// calls `onShowDeleteFlow`, which the parent screen wires to a native
/// destructive confirmation `.alert`.
///
/// The section takes both callbacks (`onSignOut`, `onShowDeleteFlow`) so
/// the parent screen owns navigation + auth wiring; this view stays a pure
/// SwiftUI section with no `@Environment` reach-ins.
struct AccountSection: View {

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
                Text(user.email ?? "Email unavailable")
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityIdentifier("settings-account-email")
            }
            Button("Sign Out") {
                // KEEP: onSignOut is supplied by the host; the underlying
                // signOut runs against an actor (RishiAuthService). Outer Task
                // chains the await — final session-store + UI updates are
                // owned by the host @MainActor callback.
                Task { await onSignOut() }
            }
            .foregroundStyle(RishiColor.accent)
            .accessibilityIdentifier("settings-account-signout")

//            Button("Delete Account…") {
//                onShowDeleteFlow()
//            }
//            .foregroundStyle(RishiColor.danger)
//            .accessibilityIdentifier("settings-account-delete")
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
                id: UUID(),
                email: "reader@example.com",
                name: "Sample Reader",
               
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
