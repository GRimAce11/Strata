import Foundation
import SwiftData

/// Populate a destination property with a value computed from each
/// already-migrated entity.
///
/// Backfill always runs in the `didMigrate` phase against the destination
/// schema. The closure receives the entity in its post-migration state,
/// so any properties carried over by SwiftData's default migration or
/// restored by an earlier ``Rename`` are visible.
///
/// Use ``Backfill`` for:
/// - Filling new non-optional columns from existing data
///   (e.g. `publishedAt` derived from `createdAt`)
/// - Computed slugs, hashes, or normalized forms
///
/// Use ``Rename`` if you simply want to move a value across a name change
/// — ``Backfill`` does not capture source-only data.
///
/// ```swift
/// Backfill(\PostV2.slug) { post in
///     slugify(post.name)
/// }
/// ```
public struct Backfill<Model: PersistentModel, Value: Sendable>: MigrationOperation, @unchecked Sendable {

    // See Rename.swift for why @unchecked Sendable is sound here.
    public let keyPath: ReferenceWritableKeyPath<Model, Value>
    public let compute: @Sendable (Model) throws -> Value
    public let description: String

    /// If `true` (the default), the backfill overwrites any existing
    /// destination value with the result of `compute`. Set to `false` to
    /// run the closure only against entities whose destination value is
    /// `nil` — useful when a migration leaves some rows already populated
    /// (e.g. by an earlier ``Rename``).
    public let overwrite: Bool

    /// Rows fetched and written per batch. Lower this to reduce peak
    /// memory and dirty-object accumulation on very large stores.
    public let batchSize: Int

    public init(
        _ keyPath: ReferenceWritableKeyPath<Model, Value>,
        overwrite: Bool = true,
        batchSize: Int = 500,
        compute: @escaping @Sendable (Model) throws -> Value
    ) {
        self.keyPath = keyPath
        self.compute = compute
        self.overwrite = overwrite
        self.batchSize = batchSize
        self.description = "Backfill \(Model.self).\(_strataPropertyName(keyPath))" +
            (overwrite ? " (overwrite)" : "")
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        var written = 0
        var total = 0
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Model>()
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            total += batch.count
            for object in batch {
                if !overwrite, isPresent(object[keyPath: keyPath]) { continue }
                object[keyPath: keyPath] = try compute(object)
                written += 1
            }
            // Flush each batch so the dirty-object graph stays bounded.
            // The orchestrator in SchemaMigrationPlanConversion saves again
            // after all body ops complete; that second save is a safe no-op.
            if context.hasChanges { try context.save() }
            offset += batch.count
            if batch.count < batchSize { break }
        }
        StrataLog.operation.debug(
            "Backfill wrote \(written, privacy: .public)/\(total, privacy: .public) row(s) for \(self.description, privacy: .public)"
        )
    }

    /// Returns `true` if the value is non-nil; consulted only when
    /// `overwrite == false`. For non-optional `Value` types this is
    /// always `true`, meaning `overwrite: false` is only meaningful
    /// for `Optional`-valued backfills.
    private func isPresent(_ value: Value) -> Bool {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional, mirror.children.isEmpty { return false }
        return true
    }
}
