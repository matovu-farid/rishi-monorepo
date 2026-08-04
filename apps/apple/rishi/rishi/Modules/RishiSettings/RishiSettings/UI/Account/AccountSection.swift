import SwiftUI



/// SET-01 Account section. Shows the signed-in user's email,
/// a Sign Out button, and a destructive "Delete Account" row. Tapping the row
/// calls `onShowDeleteFlow`, which the parent screen wires to a native
/// destructive confirmation `.alert`.
///
/// The section takes both callbacks (`onSignOut`, `onShowDeleteFlow`) so
/// the parent screen owns navigation + auth wiring; this view stays a pure
/// SwiftUI section with no `@Environment` reach-ins.
struct AccountSection: View {

    static let deleteAccountButtonTitle = "Delete Account…"

    public let user: User
    public let onSignOut: () async -> Void
    public let onShowDeleteFlow: () -> Void
    public let onEditUsername: () -> Void
    public let onCopyUsername: (String) -> Void
    @State private var usernameCopied = false
    @State private var copyFeedbackGeneration = 0

    public init(
        user: User,
        onSignOut: @escaping () async -> Void,
        onShowDeleteFlow: @escaping () -> Void,
        onEditUsername: @escaping () -> Void = {},
        onCopyUsername: @escaping (String) -> Void = UsernameClipboard.copy
    ) {
        self.user = user
        self.onSignOut = onSignOut
        self.onShowDeleteFlow = onShowDeleteFlow
        self.onEditUsername = onEditUsername
        self.onCopyUsername = onCopyUsername
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
            if let username = user.username, !username.isEmpty {
                HStack {
                    Button {
                        onEditUsername()
                    } label: {
                        HStack {
                            Text("Username")
                                .font(RishiTypography.body)
                                .foregroundStyle(RishiColor.textPrimary)
                            Spacer()
                            Text(username)
                                .font(RishiTypography.caption)
                                .foregroundStyle(RishiColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-account-username")

                    Button {
                        onCopyUsername(username)
                        usernameCopied = true
                        copyFeedbackGeneration += 1
                        let generation = copyFeedbackGeneration
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard copyFeedbackGeneration == generation else { return }
                            usernameCopied = false
                        }
                    } label: {
                        Image(systemName: usernameCopied ? "checkmark" : "doc.on.doc")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(RishiColor.textSecondary)
                    .accessibilityLabel(usernameCopied ? "Username copied" : "Copy username")
                    .accessibilityIdentifier("settings-account-username-copy")
                }
            } else {
                Button {
                    onEditUsername()
                } label: {
                    HStack {
                        Text("Username")
                            .font(RishiTypography.body)
                            .foregroundStyle(RishiColor.textPrimary)
                        Spacer()
                        Text("Not set")
                            .font(RishiTypography.caption)
                            .foregroundStyle(RishiColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-account-username")
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

            Button(Self.deleteAccountButtonTitle) {
                onShowDeleteFlow()
            }
            .foregroundStyle(RishiColor.danger)
            .accessibilityIdentifier("settings-account-delete")
        } header: {
            Text("Account")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
        .onChange(of: user.username) { _, _ in
            copyFeedbackGeneration += 1
            usernameCopied = false
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
