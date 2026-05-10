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

    public init(
        _ keyPath: ReferenceWritableKeyPath<Model, Value>,
        overwrite: Bool = true,
        compute: @escaping @Sendable (Model) throws -> Value
    ) {
        self.keyPath = keyPath
        self.compute = compute
        self.overwrite = overwrite
        self.description = "Backfill \(Model.self).\(_strataPropertyName(keyPath))" +
            (overwrite ? " (overwrite)" : "")
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        let objects = try context.fetch(FetchDescriptor<Model>())
        var written = 0
        for object in objects {
            if !overwrite, isPresent(object[keyPath: keyPath]) {
                continue
            }
            object[keyPath: keyPath] = try compute(object)
            written += 1
        }
        StrataLog.operation.debug(
            "Backfill wrote \(written, privacy: .public)/\(objects.count, privacy: .public) row(s) for \(self.description, privacy: .public)"
        )
    }

    /// Returns `true` if the value is non-nil; consulted only when
    /// `overwrite == false`. For non-optional `Value` types this is
    /// always `true`, which means `overwrite: false` is only useful for
    /// `Optional`-valued backfills.
    private func isPresent(_ value: Value) -> Bool {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional, mirror.children.isEmpty {
            return false
        }
        return true
    }
}
