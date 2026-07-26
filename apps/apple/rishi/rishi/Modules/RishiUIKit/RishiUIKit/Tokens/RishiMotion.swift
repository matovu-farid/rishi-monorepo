import Foundation

/// Motion timing tokens. Use with the `.rishiAnimation(_:reduce:)` modifier
/// rather than passing directly to `.animation(_:value:)` so reduced-motion
/// preferences are honored consistently.
public enum RishiMotion {
    public static let fast:     Duration = .milliseconds(180)
    public static let standard: Duration = .milliseconds(320)
    public static let slow:     Duration = .milliseconds(500)
}
