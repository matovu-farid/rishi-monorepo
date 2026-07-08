import Foundation
import SwiftData

/// Public surface for the RishiDB package.
public enum RishiDB {

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
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Create the shared SwiftData-backed persistence facade.
    public static func makeStore(at url: URL) throws -> RishiDBStore {
        try makePersistenceStore(at: url)
    }

    /// Deprecated compatibility shim for legacy queue-shaped callers.
    @available(*, deprecated, renamed: "makeStore(at:)")
    public static func makeDatabaseQueue(at url: URL) throws -> RishiDBStore {
        try makePersistenceStore(at: url)
    }

    /// Deprecated compatibility shim for legacy pool-shaped callers.
    @available(*, deprecated, renamed: "makeStore(at:)")
    public static func makeDatabasePool(at url: URL) throws -> RishiDBStore {
        try makePersistenceStore(at: url)
    }

    private static func makePersistenceStore(at url: URL) throws -> RishiDBStore {
        RishiDBStore(container: try makeModelContainer(at: url))
    }
}
