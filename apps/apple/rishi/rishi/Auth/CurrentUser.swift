//
//  CurrentUser.swift
//  rishi
//
//  Created by Farid Matovu on 04/07/2026.
//

import Foundation
import RishiCore

@Observable
final class CurrentUserBox {
    enum State {
        case loading
        case signedIn(user: User)
        case signedOut
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
    func signout(){
        Keychain.delete(.accessToken)
        Keychain.delete(.refreshToken)
        Keychain.delete(.userId)
        Task {
            try? await KeychainSessionStore().delete()
        }
        self.state = .signedOut
    }
    
    
  
    
}
