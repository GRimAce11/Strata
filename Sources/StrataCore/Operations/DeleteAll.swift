import Foundation
import SwiftData

/// Delete every entity of a given model.
///
/// Useful when a schema version retires an entire entity, or when a
/// transform replaces a source set wholesale. Runs in `didMigrate`
/// against the destination schema (where the model is still being
/// dropped or has just been replaced).
///
/// ```swift
/// DeleteAll(LegacyCacheEntryV2.self)
/// ```
public struct DeleteAll<Model: PersistentModel>: MigrationOperation {
    public let description: String

    /// Rows deleted per batch. Default 500.
    public let batchSize: Int

    public init(_ model: Model.Type, batchSize: Int = 500) {
        self.description = "DeleteAll \(Model.self)"
        self.batchSize = batchSize
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        // Fetch without offset: after each save the deleted rows are gone,
        // so the next fetch at offset 0 returns the next page of survivors.
        var removed = 0
        while true {
            var descriptor = FetchDescriptor<Model>()
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for object in batch { context.delete(object) }
            try context.save()
            removed += batch.count
        }
        StrataLog.operation.debug(
            "DeleteAll removed \(removed, privacy: .public) row(s) of \(String(describing: Model.self), privacy: .public)"
        )
    }
}

/// Delete entities matching a predicate.
///
/// ```swift
/// DeleteWhere(PostV2.self) { $0.isLegacy }
/// ```
///
/// > Note: The predicate is evaluated in Swift (not pushed down to
/// > sqlite), so this is `O(n)` in the number of entities. For very
/// > large stores where only a subset of rows match, prefer a
/// > ``CustomOperation`` with a `Predicate<Model>` pushed to SQLite.
///
/// > Note: This operation uses offset-based pagination and accumulates
/// > deletions in memory before the orchestrator flushes them. Peak
/// > memory is proportional to the number of matching rows.
public struct DeleteWhere<Model: PersistentModel>: MigrationOperation {
    public let description: String
    public let predicate: @Sendable (Model) -> Bool

    /// Rows scanned per fetch. Default 500.
    public let batchSize: Int

    public init(
        _ model: Model.Type,
        batchSize: Int = 500,
        where predicate: @escaping @Sendable (Model) -> Bool
    ) {
        self.description = "DeleteWhere \(Model.self)"
        self.batchSize = batchSize
        self.predicate = predicate
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        // Offset-based pagination: we accumulate deletions across batches without
        // saving between them, so offset remains valid (deleted rows are still
        // present in the database until the orchestrator's final save).
        // Peak memory is O(matching rows) — documented above.
        var removed = 0
        var total = 0
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Model>()
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            total += batch.count
            for object in batch where predicate(object) {
                context.delete(object)
                removed += 1
            }
            offset += batch.count
            if batch.count < batchSize { break }
        }
        StrataLog.operation.debug(
            "DeleteWhere removed \(removed, privacy: .public)/\(total, privacy: .public) row(s) of \(String(describing: Model.self), privacy: .public)"
        )
    }
}
