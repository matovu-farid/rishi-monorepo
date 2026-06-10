import Foundation
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

/// Wave-1 link-prover. Forces the build system to resolve and link
/// every Readium product `RishiReader` depends on. Wave-2/3 plans
/// replace this enum's body with real loader / VM code; until then,
/// the type references below are the minimal surface that fails to
/// compile if any product is missing from Package.swift.
///
/// `internal` (not `public`) — this is package-private scaffolding.
enum EPUBReadiumImport {

    /// Returns the static description of the Readium types we depend on.
    /// Touching every type via `String(describing:)` forces the linker
    /// to keep the symbols, so a stripped Release build still proves
    /// the dep graph resolved end-to-end.
    static func linkProof() -> String {
        var parts: [String] = [
            String(describing: Publication.self),              // ReadiumShared
            String(describing: AssetRetriever.self),           // ReadiumShared
            String(describing: DefaultHTTPClient.self),        // ReadiumShared
            String(describing: Locator.self),                  // ReadiumShared
            String(describing: PublicationOpener.self),        // ReadiumStreamer
            String(describing: DefaultPublicationParser.self), // ReadiumStreamer
        ]
        #if canImport(UIKit)
        // EPUBNavigatorViewController / Decoration are iOS / Catalyst only.
        parts.append(String(describing: EPUBNavigatorViewController.self)) // ReadiumNavigator
        parts.append(String(describing: Decoration.self))                  // ReadiumNavigator
        #endif
        return parts.joined(separator: ",")
    }
}
