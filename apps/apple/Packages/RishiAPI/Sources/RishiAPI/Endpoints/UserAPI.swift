//
//  File.swift
//  RishiAPI
//
//  Created by Farid Matovu on 04/07/2026.
//

import Foundation
import RishiCore


public struct UserGetEndpoint: WorkerEndpoint {
    public typealias Response = User
    
   
    public init() {}
    
    public let method: HTTPMethod = .GET
    
    public let path: String = "/api/user"
    
  
    
    
}
