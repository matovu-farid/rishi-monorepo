import Foundation
import SwiftData

public actor RishiDBStore {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func read<T>(_ operation: @Sendable (ModelContext) throws -> T) async rethrows -> T {
        try operation(context)
    }

    public func write<T>(_ operation: @Sendable (ModelContext) throws -> T) async throws -> T {
        do {
            let value = try operation(context)
            if context.hasChanges {
                try context.save()
            }
            return value
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }
}
