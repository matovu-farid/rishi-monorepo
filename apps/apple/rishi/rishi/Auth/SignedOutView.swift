import AuthenticationServices



import SwiftUI
import GoogleSignInSwift

struct SignedOutView: View {

    private let credentialAdapter: CredentialAuthenticationAdapter?

    init() { credentialAdapter = nil }

    init(credentialAdapter: CredentialAuthenticationAdapter) {
        self.credentialAdapter = credentialAdapter
    }

    @Environment(\.rishiAuthService) private var authService: (any AuthService)?
    
    @Environment(\.appDependencies) private var legacyDependencies

    private var deps: AppDependencies? {
        if let credentialAdapter { return credentialAdapter.appDependencies }
        return legacyDependencies
    }
    
    var workerClient: WorkerClient? {
        if let credentialAdapter { return credentialAdapter.workerClient }
        return deps?.services?.workerClient
    }
    var onSignedIn: (User) -> Void = { _ in }
    @State var currentUser:User? = nil
    @State var isSignedIn:Bool = false
    @Environment(CurrentUserBox.self) private var currentUserBox
    


    @State private var viewModel = SignedOutViewModel(authService: nil)
    @State private var pendingAppleNonce: String?
    @State private var pendingAppleAttempt: CredentialAuthenticationAttempt?
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
        guard !signInInFlight, let deps, let workerClient else {
            viewModel.recordFailure(RishiError.network(
                code: "email_sign_in_unavailable",
                message: "Authentication is not available."
            ))
            return
        }
        signInInFlight = true
        let attempt = credentialAdapter?.beginAttempt()
        Task { @MainActor in
            defer { signInInFlight = false }
            do {
                let auth: EmailPasswordSignInEndpoint.Response
                if showsEmailPasswordForm {
                    auth = try await exchange(TestEmailPasswordSignInEndpoint(email: email, password: password),
                                              workerClient: workerClient, attempt: attempt)
                } else {
                    auth = try await exchange(EmailPasswordSignInEndpoint(email: email, password: password),
                                              workerClient: workerClient, attempt: attempt)
                }
                try await completeSignIn(auth, deps: deps, attempt: attempt)
            } catch {
                recordFailure(error, attempt: attempt)
            }
        }
    }
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        guard !signInInFlight else { return }
        signInInFlight = true
        pendingAppleAttempt = credentialAdapter?.beginAttempt()
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
        let attempt = pendingAppleAttempt
        defer {
            pendingAppleNonce = nil
            pendingAppleAttempt = nil
            signInInFlight = false
        }

        switch result {
        case .success(let authorization):

            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                recordFailure(RishiError.network(
                    code: "siwa_invalid_credential",
                    message: "Apple returned an unsupported credential."
                ), attempt: attempt)
                return
            }

            guard let token = credential.identityToken,
                  let jwt = String(data: token, encoding: .utf8) else {
                recordFailure(RishiError.network(
                    code: "siwa_missing_identity_token",
                    message: "Apple did not return an identity token."
                ), attempt: attempt)
                return
            }

            guard let deps, let workerClient else {
                recordFailure(RishiError.network(
                    code: "siwa_unavailable",
                    message: "Authentication is not available."
                ), attempt: attempt)
                return
            }

            do {
                let credentialAdapter = self.credentialAdapter
                let auth = try await AppleSignInExchange(send: { body in
                    if let credentialAdapter {
                        guard let attempt else { throw CredentialAuthenticationFailure.accountChanged }
                        return try await credentialAdapter.exchange(JWTEndPoint(body: body), attempt: attempt)
                    }
                    return try await workerClient.send(JWTEndPoint(body: body))
                }).run(
                    identityToken: jwt,
                    authorizationCode: credential.authorizationCode,
                    nonce: requestNonce
                )

                    try await completeSignIn(
                        auth,
                        deps: deps,
                        invalidUserIDCode: "siwa_invalid_user_id",
                        attempt: attempt
                    )
            } catch {
                print("Apple sign-in Worker exchange failed: \(error)")
                recordFailure(error, attempt: attempt)
            }

        case .failure(let error):
            print("Apple authorization failed: \(error)")
            recordFailure(error, attempt: attempt)
        }
    }

    private func signInWithGoogle() {
        guard !signInInFlight else { return }
        signInInFlight = true
        let attempt = credentialAdapter?.beginAttempt()

        Task { @MainActor in
            defer { signInInFlight = false }

            guard let deps, let workerClient else {
                recordFailure(RishiError.network(
                    code: "google_sign_in_unavailable",
                    message: "Authentication is not available."
                ), attempt: attempt)
                return
            }

            do {
                let identityToken = try await googleSignInCoordinator.signIn()
                if let credentialAdapter, let attempt, !credentialAdapter.isCurrent(attempt) {
                    throw CredentialAuthenticationFailure.accountChanged
                }
                let auth = try await exchange(
                    GoogleAuthEndpoint(
                        body: GoogleAuthEndpoint.Body(identityToken: identityToken)
                    ), workerClient: workerClient, attempt: attempt
                )
                try await completeSignIn(
                    auth,
                    deps: deps,
                    invalidUserIDCode: "google_invalid_user_id",
                    attempt: attempt
                )
            } catch {
                guard !GoogleSignInCoordinator.isCancellation(error) else { return }
                if let credentialAdapter {
                    guard let attempt, credentialAdapter.mayReportFailure(for: attempt) else { return }
                }
                GoogleSignInCoordinator.signOut()
                print("Google sign-in Worker exchange failed: \(error)")
                viewModel.recordFailure(error)
            }
        }
    }

    private func completeSignIn(
        _ auth: JWTEndPoint.ResponseType,
        deps: AppDependencies,
        invalidUserIDCode: String,
        attempt: CredentialAuthenticationAttempt?
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

        if let credentialAdapter {
            guard let attempt else { throw CredentialAuthenticationFailure.accountChanged }
            try await credentialAdapter.completeSignIn(
                session: Session(token: auth.accessToken, userId: auth.userId, email: auth.user.email),
                refreshToken: auth.refreshToken, user: auth.user, attempt: attempt, debugOnboarding: false
            ) {
                currentUser = auth.user
                currentUserBox.signIn(user: auth.user)
                isSignedIn = true
            }
            return
        }

        throw CredentialAuthenticationFailure.accountChanged
    }

    private func completeSignIn(
        _ auth: EmailPasswordSignInEndpoint.Response,
        deps: AppDependencies,
        attempt: CredentialAuthenticationAttempt?
    ) async throws {
        let userID = DerivedUserID.from(auth.user.id)
        if let credentialAdapter {
            guard let attempt else { throw CredentialAuthenticationFailure.accountChanged }
            let user = User(id: userID, email: auth.user.email, name: auth.user.name)
            try await credentialAdapter.completeSignIn(
                session: Session(token: auth.token, userId: auth.user.id, email: auth.user.email),
                refreshToken: nil, user: user, attempt: attempt,
                debugOnboarding: showsEmailPasswordForm
            ) {
                currentUser = user
                currentUserBox.signIn(user: user)
                isSignedIn = true
            }
            return
        }
        throw CredentialAuthenticationFailure.accountChanged
    }

    private func recordFailure(_ error: Error, attempt: CredentialAuthenticationAttempt?) {
        if let credentialAdapter {
            guard let attempt, credentialAdapter.mayReportFailure(for: attempt) else { return }
        }
        viewModel.recordFailure(error)
    }

    private func exchange<E: WorkerEndpoint>(_ endpoint: E, workerClient: WorkerClient,
                                             attempt: CredentialAuthenticationAttempt?) async throws -> E.Response {
        if let credentialAdapter {
            guard let attempt else { throw CredentialAuthenticationFailure.accountChanged }
            return try await credentialAdapter.exchange(endpoint, attempt: attempt)
        }
        return try await workerClient.send(endpoint)
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
