//
//  File.swift
//  RishiAPI
//
//  Created by Farid Matovu on 04/07/2026.
//

import Foundation
struct RefreshEndpoint: WorkerEndpoint {
    
    struct Body: Encodable {
        let refreshToken: String
    }
    
    struct Response: Decodable {
        let accessToken: String
        let refreshToken: String
    }
    
    let body: Body
    
    let path = "/auth/refresh"
    let method: HTTPMethod = .POST
}
