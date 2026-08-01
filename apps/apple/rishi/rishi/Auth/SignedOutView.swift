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
    @State private var appleSignInInFlight = false
    @State private var appleAuthorizationConsumed = false

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
        }
    }
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        guard !appleSignInInFlight else { return }
        appleSignInInFlight = true
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
            appleSignInInFlight = false
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

                    guard let userId = UUID(uuidString: auth.userId) else {
                        throw RishiError.network(
                            code: "siwa_invalid_user_id",
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
            } catch {
                viewModel.recordFailure(error)
            }

        case .failure(let error):
            viewModel.recordFailure(error)
        }
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
        .disabled(appleSignInInFlight)
        .signInWithAppleButtonStyle(.black)
        .frame(maxWidth: 400)
        .frame(height: 44)
        .cornerRadius(10)
    }

    @ViewBuilder
    private var errorRow: some View {
        if viewModel.isLoading {
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
