import Foundation
import SwiftData

/// The user-facing description of how a SwiftData store should be migrated
/// from one schema version to another (or through several in sequence).
///
/// A plan owns:
///
/// - An ordered list of ``Stage`` values, each describing a single
///   `from → to` transition.
/// - The schemas the plan knows about. These must include every
///   `VersionedSchema` referenced by any stage, in version order.
/// - Optional ``MigrationPlan/preMigration`` and ``MigrationPlan/postMigration``
///   hooks that run once per `SafeModelContainer.make` invocation, regardless
///   of how many stages execute.
///
/// ```swift
/// let plan = MigrationPlan(schemas: [
///     SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self
/// ]) {
///     Stage(from: SchemaV1.self, to: SchemaV2.self)        // lightweight
///     Stage(from: SchemaV2.self, to: SchemaV3.self) {       // custom
///         Rename(\PostV2.body, to: \PostV3.content)
///     }
///     Stage(from: SchemaV3.self, to: SchemaV4.self) {
///         Backfill(\PostV4.publishedAt) { $0.createdAt }
///         Assert.noNulls(\PostV4.publishedAt)
///     }
/// }
/// ```
public struct MigrationPlan: Sendable {
    public let schemas: [any VersionedSchema.Type]
    public let stages: [Stage]

    public typealias Hook = @Sendable (HookContext) throws -> Void

    public let preMigration: Hook?
    public let postMigration: Hook?

    /// Information passed to ``Hook`` closures.
    public struct HookContext: Sendable {
        public let storeURL: URL
        public let sourceVersion: String
        public let destinationVersion: String
    }

    public init(
        schemas: [any VersionedSchema.Type],
        preMigration: Hook? = nil,
        postMigration: Hook? = nil,
        @MigrationPlanBuilder _ build: () -> [Stage]
    ) {
        self.schemas = schemas
        self.stages = build()
        self.preMigration = preMigration
        self.postMigration = postMigration
    }

    /// Static validation that does not require touching the store.
    /// Returns the (non-empty) list of reasons the plan cannot run, or
    /// an empty array if the plan looks structurally fine.
    public func validate() -> [String] {
        var reasons: [String] = []

        if stages.isEmpty {
            reasons.append("Plan has no stages.")
        }

        let knownNames = Set(schemas.map { String(describing: $0) })
        for (i, stage) in stages.enumerated() {
            let fromName = String(describing: stage.fromSchema)
            let toName = String(describing: stage.toSchema)
            if !knownNames.contains(fromName) {
                reasons.append("Stage \(i): source schema \(fromName) not in plan.schemas")
            }
            if !knownNames.contains(toName) {
                reasons.append("Stage \(i): destination schema \(toName) not in plan.schemas")
            }
        }

        // Adjacency: every stage's destination must equal the next stage's source.
        for (i, pair) in zip(stages, stages.dropFirst()).enumerated() {
            let lhsTo = String(describing: pair.0.toSchema)
            let rhsFrom = String(describing: pair.1.fromSchema)
            if lhsTo != rhsFrom {
                reasons.append("Stage \(i)→\(i + 1) gap: \(lhsTo) is not the source of the next stage (\(rhsFrom)).")
            }
        }
        return reasons
    }
}
