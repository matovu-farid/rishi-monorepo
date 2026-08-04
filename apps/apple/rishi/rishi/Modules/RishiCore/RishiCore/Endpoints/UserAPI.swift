//
//  File.swift
//  RishiAPI
//
//  Created by Farid Matovu on 04/07/2026.
//

import Foundation


public struct UserGetEndpoint: WorkerEndpoint {
    public typealias Response = User
    
   
    public init() {}
    
    public let method: HTTPMethod = .GET
    
    public let path: String = "/api/user"
    
  
    
    
}

public struct UserUpdateEndpoint: WorkerEndpointWithBody {
    public struct Body: Encodable, Sendable, Equatable {
        public let username: String

        public init(username: String) {
            self.username = username
        }
    }

    public typealias Response = User

    public let method: HTTPMethod = .PATCH
    public let path: String = "/api/user"
    public let body: Body

    public init(username: String) {
        self.body = Body(username: username)
    }
}
