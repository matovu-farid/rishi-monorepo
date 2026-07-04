//
//  Keychain.swift
//  rishi
//
//  Created by Farid Matovu on 04/07/2026.
//

import Foundation
import Security

public enum Keychain {
    
    public enum Key: String {
        case accessToken
        case refreshToken
        case userId
    }
    
    public static func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
        ]
        
        // Replace existing value if present.
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError(status)
        }
    }
    
    public static func load(_ key: Key) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        
        var result: AnyObject?
        
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        
        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            
            return string
            
        case errSecItemNotFound:
            return nil
            
        default:
            throw KeychainError(status)
        }
    }
    
    public static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainError: Error {
    let status: OSStatus
    init(_ status: OSStatus) {
        self.status = status
    }
}
