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

    public init(_ model: Model.Type) {
        self.description = "DeleteAll \(Model.self)"
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        let objects = try context.fetch(FetchDescriptor<Model>())
        for object in objects {
            context.delete(object)
        }
        StrataLog.operation.debug(
            "DeleteAll removed \(objects.count, privacy: .public) row(s) of \(String(describing: Model.self), privacy: .public)"
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
/// > large stores, prefer a ``CustomOperation`` that uses a
/// > `Predicate<Model>` directly.
public struct DeleteWhere<Model: PersistentModel>: MigrationOperation {
    public let description: String
    public let predicate: @Sendable (Model) -> Bool

    public init(_ model: Model.Type, where predicate: @escaping @Sendable (Model) -> Bool) {
        self.description = "DeleteWhere \(Model.self)"
        self.predicate = predicate
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        let objects = try context.fetch(FetchDescriptor<Model>())
        var removed = 0
        for object in objects where predicate(object) {
            context.delete(object)
            removed += 1
        }
        StrataLog.operation.debug(
            "DeleteWhere removed \(removed, privacy: .public)/\(objects.count, privacy: .public) row(s) of \(String(describing: Model.self), privacy: .public)"
        )
    }
}
