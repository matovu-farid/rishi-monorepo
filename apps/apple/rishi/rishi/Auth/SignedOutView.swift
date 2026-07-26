import AuthenticationServices



import SwiftUI

struct SignedOutView: View {

    @Environment(\.rishiAuthService) private var authService: (any AuthService)?
    
    @Environment(\.appDependencies) private var deps
    
    var workerClient: WorkerClient? {deps?.workerClient}
    var onSignedIn: (User) -> Void = { _ in }
    @State var currentUser:User? = nil
    @State var isSignedIn:Bool = false
    @Environment(CurrentUserBox.self) private var currentUserBox
    


    @State private var viewModel = SignedOutViewModel(authService: nil)

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
        request.requestedScopes = [
            .fullName,
            .email
        ]
    }
    func handle(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                return
            }
            
            let userID = credential.user
            let email = credential.email
            let fullName = credential.fullName
            
            print("User ID:", userID)
            print("Email:", email ?? "nil")
            print("Name:", fullName?.givenName ?? "nil")
            guard let token = credential.identityToken,
                  let jwt = String(data: token, encoding: .utf8) else {
                return
            }
           
     
            let endpoint = JWTEndPoint(body: .init(identityToken: jwt))
            if let workerClient  {
                let auth = try? await workerClient.send(endpoint)
                if let auth {
                    
                    print(result)
                    try? Keychain.save(
                        auth.accessToken,
                        for: .accessToken
                    )
                    
                    try? Keychain.save(
                        auth.refreshToken,
                        for: .refreshToken
                    )
                    try? Keychain.save(
                        auth.userId,
                        for: .userId
                    )
                    try? await KeychainSessionStore().save(
                        Session(
                            token: auth.accessToken,
                            userId: auth.userId,
                            email: auth.user.email
                        )
                    )
                    currentUser = auth.user
                    
                    if let userId = UUID(uuidString: auth.userId){
                        deps?.setUserId(userId)
                        isSignedIn = true
                        
                    }
                    currentUserBox.signIn(user: auth.user)
                    await deps?.entitlementRefreshCoordinator.refreshIfSignedIn(
                        reason: .signIn
                    )
                }
            }
            
            
            
        case .failure(let error):
            print(error)
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
