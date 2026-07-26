//
//  File.swift
//  RishiAPI
//
//  Created by Farid Matovu on 03/07/2026.
//

import Foundation

public struct GroupId: Decodable,Sendable {
     public var value: String
}
    
public struct GroupIDEndpoint:WorkerEndpoint {
    public typealias Response = GroupId
    public init() {}
    

    
    public let method: HTTPMethod = .GET
    
    public let path =  "/api/groupID"

}
