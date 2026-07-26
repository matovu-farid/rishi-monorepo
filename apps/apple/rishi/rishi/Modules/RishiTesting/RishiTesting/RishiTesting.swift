// RishiTesting — in-memory store implementations, fake services, fixtures,
// and conformance helpers for every protocol declared in RishiCore.
// Link-isolated to test targets — never compiled into the release app binary.

import Foundation

public enum RishiTesting {
    public static let apiVersion = "1.0.0"
}

/// Error thrown by conformance helpers when a behavioral expectation fails.
/// Helpers throw rather than using XCTest assertions so this package can be
/// consumed by Swift Testing test targets without dragging XCTest in.
public enum RishiTestingError: Error, CustomStringConvertible {
    case expected(String)
    case unexpected(String)

    public var description: String {
        switch self {
        case .expected(let msg):   return "RishiTesting expectation failed: \(msg)"
        case .unexpected(let msg): return "RishiTesting unexpected condition: \(msg)"
        }
    }
}
