import Foundation

/// RishiSettings — Feature-layer package orchestrating the in-app Settings
/// screen. SET-01 sections: Account / Reader / Audio / Sync / About.
/// SET-02: Telemetry opt-in toggle. SET-03: Account-deletion flow.
///
/// Settings is the bottom-of-tree orchestrator by convention — it depends
/// on multiple sibling Feature packages (Sync / Audio / Reader / Billing)
/// to embed their existing rows. This package owns ONLY the top-level
/// screen + the Account/About/Telemetry sections; sibling packages own
/// the rows the user sees in Sync / Reader / Audio sections.
public enum RishiSettings {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    public static let version = "0.1.0-scaffold"
}
