import Foundation
import SwiftData

/// Public surface for the RishiDB package.
public enum RishiDB {

    public enum ContainerError: Error, Sendable {
        case migrationRequired(String)
    }

    /// Marker for the public RishiDB API version. Bump when the surface breaks.
    static let apiVersion = "0.3.0-swiftdata"

    /// Create the SwiftData `ModelContainer` used by RishiDB's stores.
    ///
    /// Pass `URL(fileURLWithPath: ":memory:")` for a throwaway in-memory store
    /// in tests; any other URL is treated as the on-disk backing file.
    public static func makeModelContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(RishiDBModelTypes.all)
        let configuration: ModelConfiguration
        if url.lastPathComponent == ":memory:" {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            configuration = ModelConfiguration(url: url)
        }
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Never delete, replace, or silently recreate an existing store. SwiftData
            // performs its safe additive migration here; incompatible stores surface
            // an actionable error to the caller instead.
            throw ContainerError.migrationRequired(String(describing: error))
        }
    }

    /// Create the shared SwiftData-backed persistence facade.
    public static func makeStore(at url: URL) throws -> RishiDBStore {
        try makePersistenceStore(at: url)
    }

    private static func makePersistenceStore(at url: URL) throws -> RishiDBStore {
        RishiDBStore(container: try makeModelContainer(at: url))
    }
}
