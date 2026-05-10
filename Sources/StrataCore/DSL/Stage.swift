import Foundation
import SwiftData

/// One declarative migration from a source ``VersionedSchema`` to a
/// destination ``VersionedSchema``.
///
/// A stage owns the operations that should run as part of that transition,
/// plus optional hooks that fire before and after the operations execute.
///
/// Two construction modes:
///
/// 1. `Stage(from:to:)` with no body → a lightweight migration (SwiftData
///    figures out the column shape on its own; no user code runs).
/// 2. `Stage(from:to:) { ... }` with a builder body → a custom migration
///    composed of ``MigrationOperation`` values.
///
/// ```swift
/// // lightweight
/// Stage(from: SchemaV1.self, to: SchemaV2.self)
///
/// // custom
/// Stage(from: SchemaV2.self, to: SchemaV3.self) {
///     Rename(\PostV2.body, to: \PostV3.content)
///     Backfill(\PostV3.publishedAt) { $0.createdAt }
///     Assert.noNulls(\PostV3.publishedAt)
/// }
/// ```
public struct Stage: Sendable {
    public let fromSchema: any VersionedSchema.Type
    public let toSchema: any VersionedSchema.Type
    public let operations: [any MigrationOperation]
    public let kind: Kind

    public enum Kind: Sendable {
        case lightweight
        case custom
    }

    /// Lightweight migration. SwiftData handles the schema transition
    /// using its built-in heuristics; no user code runs.
    public init(
        from: any VersionedSchema.Type,
        to: any VersionedSchema.Type
    ) {
        self.fromSchema = from
        self.toSchema = to
        self.operations = []
        self.kind = .lightweight
    }

    /// Custom migration composed of declarative operations.
    public init(
        from: any VersionedSchema.Type,
        to: any VersionedSchema.Type,
        @StageBuilder _ build: () -> [any MigrationOperation]
    ) {
        self.fromSchema = from
        self.toSchema = to
        // Stable sort by phase so users can write operations in any order
        // and renames still capture first, assertions still run last.
        self.operations = build().enumerated()
            .sorted { lhs, rhs in
                if lhs.element.phase != rhs.element.phase {
                    return lhs.element.phase < rhs.element.phase
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        self.kind = .custom
    }

    /// A short human-readable label for logs and reports.
    public var label: String {
        "\(String(describing: fromSchema)) → \(String(describing: toSchema))"
    }
}
