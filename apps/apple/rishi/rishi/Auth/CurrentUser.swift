//
//  CurrentUser.swift
//  rishi
//
//  Created by Farid Matovu on 04/07/2026.
//

import Foundation


@Observable
final class CurrentUserBox {
    enum State {
        case loading
        case signedIn(user: User)
        case signedOut
        case authenticationRecovery(AuthenticationRecovery)
    }
    var state: State
    
    public var isSigned:Bool {
        switch state {
        case .signedIn(user: _):
            return true
         default:
            return false
        }
    }
    init(){
        state = .signedOut
    }
    

    
    func signIn(user: User){
        self.state = .signedIn(user: user)
       
    }
    func signout() {
        // Presentation only; the app-owned account transaction owns persistence.
        state = .signedOut
    }

    /// Called only after the app-owned canonical clear has been admitted.
    /// Credential persistence belongs to that owner, not this UI projection.
    func signedOutAfterCredentialClear() {
        state = .signedOut
    }
    
    
  
    
}
