//
//  File.swift
//  RishiCore
//
//  Created by Farid Matovu on 05/07/2026.
//

import Foundation
public struct VerifyEndPont:WorkerEndpointWithBody {
    public let body: BodyType
    
    public typealias Body = BodyType
    
    public struct BodyType: Encodable,Sendable {
        public var transactionId: UInt64
        public init(transactionId: UInt64) {
            self.transactionId = transactionId
        }
    }
    
    
    public typealias Response = ResponseType
    public struct ResponseType: Decodable, Sendable {
        public let verified: Bool
        public let transaction: String
        public init(verified: Bool, transaction: String) {
            self.verified = verified
            self.transaction = transaction
        }
        
    }
    public init(body: BodyType) {
        self.body = body
    }
    
    
    public let method: HTTPMethod = .POST
    
    public let path: String = "/auth/verify-transaction"
    
    
    
}
