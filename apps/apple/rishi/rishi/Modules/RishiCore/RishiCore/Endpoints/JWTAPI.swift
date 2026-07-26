//
//  File.swift
//  RishiAPI
//
//  Created by Farid Matovu on 04/07/2026.
//

import Foundation

public struct JWTEndPoint: WorkerEndpointWithBody {
    public let body: BodyType
    
    public typealias Body = BodyType
    
    public typealias Response = ResponseType
    
    public struct ResponseType: Decodable, Equatable, Sendable {
        
       public var accessToken: String
       public var refreshToken: String
       public var userId: String
       public var user: User
    }
    
    public struct BodyType:Encodable,Sendable {
        public let identityToken: String
        public init(identityToken: String) {
            self.identityToken = identityToken
        }
    }
    
    public let method: HTTPMethod = .POST
    
    public let path =  "/auth/apple"
    
    public init(body: BodyType) {
        self.body = body
    }
    
    
}
