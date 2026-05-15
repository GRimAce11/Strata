import Foundation
import SwiftData

/// Fundamentally rebuild entities of one type into entities of another.
///
/// Use ``Transform`` when neither ``Rename`` nor ``Backfill`` is enough —
/// for example, when denormalizing a single entity into multiple rows in
/// another table, or when the source data needs computation more involved
/// than a backfill closure can express.
///
/// ## Design
///
/// SwiftData does not allow source-version and destination-version model
/// types to coexist within a single `ModelContext`: once SwiftData has
/// transformed the schema, the source types are no longer present in the
/// store. To stay honest with this constraint, ``Transform`` is two phases
/// joined by a user-defined `Snapshot` type that bridges them.
///
/// 1. `capture` runs in `willMigrate` against the source schema.
///    Produce a `Snapshot` (a `Sendable` value type) for each source
///    entity. Snapshots are accumulated in batches and stashed.
/// 2. `build` runs in `didMigrate` against the destination schema. For
///    each captured snapshot, produce one or more destination entities
///    and insert them into the supplied context.
///
/// The two-closure form is verbose by design — Transform should be rare,
/// and being explicit about which phase produces which value keeps
/// behavior easy to reason about.
///
/// ```swift
/// struct PostSnapshot: Sendable {
///     let title: String
///     let createdAt: Date
/// }
///
/// Transform(
///     from: PostV1.self,
///     to: PostV2.self,
///     capture: { old in PostSnapshot(title: old.title, createdAt: old.date) },
///     build: { context, snap in
///         let post = PostV2(name: snap.title, createdAt: snap.createdAt)
///         context.insert(post)
///     }
/// )
/// ```
public struct Transform<
    From: PersistentModel,
    To: PersistentModel,
    Snapshot: Sendable
>: MigrationOperation {

    public let capture: @Sendable (From) throws -> Snapshot
    public let build: @Sendable (ModelContext, Snapshot) throws -> Void
    public let description: String

    /// If `true`, source entities that SwiftData carried into the new
    /// schema by default are deleted before `build` runs, so the
    /// transform produces a fresh set of destination entities rather
    /// than duplicating them.
    public let replaceCarried: Bool

    /// Rows fetched per batch during `willMigrate` and during the
    /// `replaceCarried` deletion pass in `didMigrate`.
    public var batchSize: Int = 500

    // UUID-based stash key: collision-free, no _kvcKeyPathString dependency.
    private let stashKey = UUID().uuidString

    public init(
        from: From.Type,
        to: To.Type,
        replaceCarried: Bool = true,
        capture: @escaping @Sendable (From) throws -> Snapshot,
        build: @escaping @Sendable (ModelContext, Snapshot) throws -> Void
    ) {
        self.capture = capture
        self.build = build
        self.replaceCarried = replaceCarried
        self.description = "Transform \(From.self) → \(To.self)" +
            (replaceCarried ? " (replace carried)" : "")
    }

    public func willMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        var snapshots: [Snapshot] = []
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<From>()
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for source in batch {
                snapshots.append(try capture(source))
            }
            offset += batch.count
            if batch.count < batchSize { break }
        }
        stash.set(stashKey, snapshots)
        StrataLog.operation.debug(
            "Transform captured \(snapshots.count, privacy: .public) snapshot(s) for \(self.description, privacy: .public)"
        )
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        guard let snapshots: [Snapshot] = stash.get(stashKey) else { return }

        if replaceCarried {
            // Batch the deletion to avoid loading the full entity graph at once.
            // After each save the deleted rows are gone, so offset stays at 0.
            while true {
                var descriptor = FetchDescriptor<To>()
                descriptor.fetchLimit = batchSize
                let batch = try context.fetch(descriptor)
                guard !batch.isEmpty else { break }
                for entity in batch { context.delete(entity) }
                try context.save()
            }
        }

        for snapshot in snapshots {
            try build(context, snapshot)
        }
        StrataLog.operation.debug(
            "Transform built \(snapshots.count, privacy: .public) entit(y/ies) for \(self.description, privacy: .public)"
        )
    }
}
