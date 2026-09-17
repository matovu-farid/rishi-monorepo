import AuthenticationServices



import SwiftUI
import GoogleSignInSwift

struct SignedOutView: View {

    @Environment(\.rishiAuthService) private var authService: (any AuthService)?
    
    @Environment(\.appDependencies) private var deps
    
    var workerClient: WorkerClient? { deps?.services?.workerClient }
    var onSignedIn: (User) -> Void = { _ in }
    @State var currentUser:User? = nil
    @State var isSignedIn:Bool = false
    @Environment(CurrentUserBox.self) private var currentUserBox
    


    @State private var viewModel = SignedOutViewModel(authService: nil)
    @State private var pendingAppleNonce: String?
    @State private var signInInFlight = false
    @State private var appleAuthorizationConsumed = false
    @State private var googleSignInCoordinator = GoogleSignInCoordinator()
    @State private var email = ""
    @State private var password = ""
    private enum EmailPasswordField: Hashable {
        case email
        case password
    }
    @FocusState private var focusedEmailPasswordField: EmailPasswordField?

    private var showsEmailPasswordForm: Bool {
        #if DEBUG
        return RishiE2EConfiguration.isRealAuth
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack{
            ZStack{
                Color.rishiBrown
                    .opacity(0.1)
                    .ignoresSafeArea()
                
                RishiScreenScaffold(actionPlacement: .belowContent) {
                    VStack(spacing: 24){
                        Image(.rishi)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .clipShape(.rect(cornerRadius: 20))
                        VStack(spacing: 8) {
                            Text("Rishi Reader")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                            
                            Text("Read with focus, listen on the go, and seamlessly switch between text and audio.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    .padding(.horizontal, RishiSpacing.l)
                } actions: {
                    VStack(spacing: RishiSpacing.l) {
                        buttons
                        errorRow
                    }
                    .padding(.horizontal, RishiSpacing.l)
                    .padding(.bottom, RishiSpacing.l)
                }
          
                
                .task {
                    
                    viewModel.setAuthService(authService)
                    
                    viewModel.onSignedIn = onSignedIn
                }
            }
            .navigationDestination(isPresented: $isSignedIn) {
                SignedInView()
              
            }
        }
    }

    private var wordmark: some View {
        VStack(spacing: RishiSpacing.m) {
            Image("rishi")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(RishiColor.accent)

                .accessibilityHidden(true)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Rishi")
                .font(RishiTypography.titleL)
                .foregroundStyle(RishiColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var welcomeCopy: some View {
        Text("Sign in to sync your library, highlights, and conversations.")
            .font(RishiTypography.body)
            .foregroundStyle(RishiColor.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, RishiSpacing.l)
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: RishiSpacing.m) {
            if showsEmailPasswordForm {
                emailPasswordForm
            }
            appleButton
            googleButton
        }
    }

    private var emailPasswordForm: some View {
        VStack(spacing: RishiSpacing.s) {
            TextField("Email", text: $email)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedEmailPasswordField, equals: .email)
                .submitLabel(.next)
                .onSubmit {
                    focusedEmailPasswordField = .password
                }
                .accessibilityIdentifier("e2e-email-field")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focusedEmailPasswordField, equals: .password)
                .submitLabel(.go)
                .onSubmit {
                    signInWithEmailPassword()
                }
                .accessibilityIdentifier("e2e-password-field")
            Button("Sign in with email") {
                signInWithEmailPassword()
            }
            .buttonStyle(.borderedProminent)
            .disabled(signInInFlight || email.isEmpty || password.isEmpty)
            .accessibilityIdentifier("e2e-email-password-submit")
        }
        .textFieldStyle(.roundedBorder)
        #if DEBUG
        // Catalyst UI tests can expose a visible login window as disabled to
        // XCTest's event synthesizer. Giving the first field focus from
        // inside the app makes the form usable without relying on a
        // coordinate click to establish keyboard focus.
        .task(id: showsEmailPasswordForm) {
            guard showsEmailPasswordForm else { return }
            try? await Task.sleep(for: .milliseconds(100))
            // The native host still exercises the real email/password request
            // through this visible form. Supplying the disposable values to
            // the DEBUG-only form avoids Catalyst's flaky keyboard event
            // synthesis while the window is reported as disabled.
            if let e2eEmail = ProcessInfo.processInfo.environment["RISHI_E2E_EMAIL"],
               let e2ePassword = ProcessInfo.processInfo.environment["RISHI_E2E_PASSWORD"],
               !e2eEmail.isEmpty, !e2ePassword.isEmpty {
                email = e2eEmail
                password = e2ePassword
            }
            focusedEmailPasswordField = .email
        }
        #endif
    }

    private func signInWithEmailPassword() {
        guard !signInInFlight, let deps, let workerClient = deps.services?.workerClient else {
            viewModel.recordFailure(RishiError.network(
                code: "email_sign_in_unavailable",
                message: "Authentication is not available."
            ))
            return
        }
        signInInFlight = true
        Task { @MainActor in
            defer { signInInFlight = false }
            do {
                let auth: EmailPasswordSignInEndpoint.Response
                if RishiE2EConfiguration.isRealAuth {
                    auth = try await workerClient.send(
                        TestEmailPasswordSignInEndpoint(email: email, password: password)
                    )
                } else {
                    auth = try await workerClient.send(
                        EmailPasswordSignInEndpoint(email: email, password: password)
                    )
                }
                try await completeSignIn(auth, deps: deps)
            } catch {
                viewModel.recordFailure(error)
            }
        }
    }
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        guard !signInInFlight else { return }
        signInInFlight = true
        request.requestedScopes = [
            .fullName,
            .email
        ]
        let (_, nonceHex) = Nonce.generate()
        pendingAppleNonce = nonceHex
        appleAuthorizationConsumed = false
        request.nonce = nonceHex
    }
    func handle(_ result: Result<ASAuthorization, Error>) async {
        guard !appleAuthorizationConsumed, let requestNonce = pendingAppleNonce else {
            return
        }
        appleAuthorizationConsumed = true
        defer {
            pendingAppleNonce = nil
            signInInFlight = false
        }

        switch result {
        case .success(let authorization):

            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                viewModel.recordFailure(RishiError.network(
                    code: "siwa_invalid_credential",
                    message: "Apple returned an unsupported credential."
                ))
                return
            }

            guard let token = credential.identityToken,
                  let jwt = String(data: token, encoding: .utf8) else {
                viewModel.recordFailure(RishiError.network(
                    code: "siwa_missing_identity_token",
                    message: "Apple did not return an identity token."
                ))
                return
            }

            guard let deps, let workerClient = deps.services?.workerClient else {
                viewModel.recordFailure(RishiError.network(
                    code: "siwa_unavailable",
                    message: "Authentication is not available."
                ))
                return
            }

            do {
                let auth = try await AppleSignInExchange(send: { body in
                    try await workerClient.send(JWTEndPoint(body: body))
                }).run(
                    identityToken: jwt,
                    authorizationCode: credential.authorizationCode,
                    nonce: requestNonce
                )

                    try await completeSignIn(
                        auth,
                        deps: deps,
                        invalidUserIDCode: "siwa_invalid_user_id"
                    )
            } catch {
                print("Apple sign-in Worker exchange failed: \(error)")
                viewModel.recordFailure(error)
            }

        case .failure(let error):
            print("Apple authorization failed: \(error)")
            viewModel.recordFailure(error)
        }
    }

    private func signInWithGoogle() {
        guard !signInInFlight else { return }
        signInInFlight = true

        Task { @MainActor in
            defer { signInInFlight = false }

            guard let deps, let workerClient = deps.services?.workerClient else {
                viewModel.recordFailure(RishiError.network(
                    code: "google_sign_in_unavailable",
                    message: "Authentication is not available."
                ))
                return
            }

            do {
                let identityToken = try await googleSignInCoordinator.signIn()
                let auth = try await workerClient.send(
                    GoogleAuthEndpoint(
                        body: GoogleAuthEndpoint.Body(identityToken: identityToken)
                    )
                )
                try await completeSignIn(
                    auth,
                    deps: deps,
                    invalidUserIDCode: "google_invalid_user_id"
                )
            } catch {
                guard !GoogleSignInCoordinator.isCancellation(error) else { return }
                GoogleSignInCoordinator.signOut()
                print("Google sign-in Worker exchange failed: \(error)")
                viewModel.recordFailure(error)
            }
        }
    }

    private func completeSignIn(
        _ auth: JWTEndPoint.ResponseType,
        deps: AppDependencies,
        invalidUserIDCode: String
    ) async throws {
        guard let userId = UUID(uuidString: auth.userId) else {
            throw RishiError.network(
                code: invalidUserIDCode,
                message: "Authentication returned an invalid user identifier."
            )
        }
        guard auth.user.id == userId else {
            throw RishiError.network(
                code: invalidUserIDCode,
                message: "Authentication returned mismatched user identifiers."
            )
        }

        do {
            try Keychain.save(auth.accessToken, for: .accessToken)
            try Keychain.save(auth.refreshToken, for: .refreshToken)
            try Keychain.save(auth.userId, for: .userId)
            try await KeychainSessionStore().save(
                Session(token: auth.accessToken, userId: auth.userId, email: auth.user.email)
            )
        } catch {
            Keychain.delete(.accessToken)
            Keychain.delete(.refreshToken)
            Keychain.delete(.userId)
            try? await KeychainSessionStore().delete()
            throw error
        }

        guard await deps.replaceUserId(userId) else {
            Keychain.delete(.accessToken)
            Keychain.delete(.refreshToken)
            Keychain.delete(.userId)
            try? await KeychainSessionStore().delete()
            _ = await deps.replaceUserId(nil, allowDeferredCleanup: true)
            throw RishiError.network(
                code: "spotlight_transition_failed",
                message: "Unable to switch to the signed-in account. Please try again."
            )
        }
        currentUser = auth.user
        await deps.backgroundSyncLifecycle.retryPendingDeviceTokenIfAvailable(
            platform: {
                #if targetEnvironment(macCatalyst)
                    "macos-catalyst"
                #else
                    "ios"
                #endif
            }(),
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        )
        // Install the account context before the signed-in view can trigger
        // pending share redemption. Share redemption is explicit library
        // transfer and must not race the consent/account setup below.
        await deps.services?.dataUseConsentStore.setCurrentUser(auth.user.id.uuidString)
        isSignedIn = true
        currentUserBox.signIn(user: auth.user)
        await deps.services?.billing.entitlementRefreshCoordinator.refreshIfSignedIn(
            reason: .signIn
        )
    }

    private func completeSignIn(
        _ auth: EmailPasswordSignInEndpoint.Response,
        deps: AppDependencies
    ) async throws {
        let userID = DerivedUserID.from(auth.user.id)
        do {
            try Keychain.save(auth.token, for: .accessToken)
            Keychain.delete(.refreshToken)
            try Keychain.save(auth.user.id, for: .userId)
            try await KeychainSessionStore().save(
                Session(token: auth.token, userId: auth.user.id, email: auth.user.email)
            )
        } catch {
            Keychain.delete(.accessToken)
            Keychain.delete(.refreshToken)
            Keychain.delete(.userId)
            try? await KeychainSessionStore().delete()
            throw error
        }

        guard await deps.replaceUserId(userID) else {
            Keychain.delete(.accessToken)
            Keychain.delete(.refreshToken)
            Keychain.delete(.userId)
            try? await KeychainSessionStore().delete()
            _ = await deps.replaceUserId(nil, allowDeferredCleanup: true)
            throw RishiError.network(
                code: "email_sign_in_transition_failed",
                message: "Unable to switch to the signed-in account. Please try again."
            )
        }

        let user = User(id: userID, email: auth.user.email, name: auth.user.name)
        #if DEBUG
        if RishiE2EConfiguration.isRealAuth {
            await deps.services?.onboarding.state.setHasCompletedOnboarding(true)
            await deps.services?.dataUseConsentStore.setCurrentUser(userID.uuidString)
            await deps.services?.dataUseConsentStore.grant(for: userID.uuidString)
        }
        #endif
        currentUser = user
        currentUserBox.signIn(user: user)
        isSignedIn = true
        await deps.services?.billing.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .signIn)
    }

    private var appleButton: some View {
        SignInWithAppleButton(
            .signIn,
            onRequest: configure,
            onCompletion: { result in
                Task{
                    await handle(result)
                }
            }
        )
        .disabled(signInInFlight)
        .signInWithAppleButtonStyle(.black)
        .frame(maxWidth: 400)
        .frame(height: 44)
        .cornerRadius(10)
    }

    private var googleButton: some View {
        GoogleSignInButton(
            scheme: .light,
            style: .wide,
            state: signInInFlight ? .disabled : .normal,
            action: signInWithGoogle
        )
        .frame(maxWidth: 400)
        .accessibilityIdentifier("google-sign-in-button")
    }

    @ViewBuilder
    private var errorRow: some View {
        if viewModel.isLoading || signInInFlight {
            #if DEBUG
                Text("View Model loading")
            #endif
            
            ProgressView()
                .progressViewStyle(.circular)
                .accessibilityIdentifier("signed-out-progress")
        }
        if let message = viewModel.errorMessage {
            Text(message)
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.l)
                .accessibilityIdentifier("signed-out-error")
        }
    }
}

#Preview("Signed out — idle") {
    SignedOutView()
        .environment(\.rishiAuthService, nil as (any AuthService)?)
}
