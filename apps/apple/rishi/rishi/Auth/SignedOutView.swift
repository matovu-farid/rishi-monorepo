import AuthenticationServices



import SwiftUI

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
            appleButton
            googleButton
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

        currentUser = auth.user
        deps.setUserId(userId)
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
        isSignedIn = true
        currentUserBox.signIn(user: auth.user)
        await deps.services?.dataUseConsentStore.setCurrentUser(auth.user.id.uuidString)
        await deps.services?.billing.entitlementRefreshCoordinator.refreshIfSignedIn(
            reason: .signIn
        )
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
        Button(action: signInWithGoogle) {
            HStack(spacing: RishiSpacing.s) {
                Text("G")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)

                Text("Continue with Google")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
            }
            .frame(maxWidth: 400)
            .frame(height: 44)
            .background(Color.white)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(signInInFlight)
        .accessibilityLabel("Continue with Google")
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
