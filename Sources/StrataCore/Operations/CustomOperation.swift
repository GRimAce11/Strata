import Foundation
import SwiftData

/// An escape hatch for migration logic that does not fit any of the
/// declarative operations.
///
/// You supply one or both phase closures directly. The closures receive
/// the same `ModelContext` and ``MigrationStash`` that all other
/// operations get, so a ``CustomOperation`` can capture in `willMigrate`
/// and consume in `didMigrate`, or perform write-side work in just one
/// phase.
///
/// Prefer the higher-level operations (``Rename``, ``Backfill``,
/// ``Transform``, ``DeleteAll``) whenever possible — they self-document
/// in migration reports and have predictable behavior. ``CustomOperation``
/// is for the genuine one-off.
///
/// ```swift
/// CustomOperation("Reparent orphaned tags") { context in
///     // didMigrate body — destination schema
///     for tag in try context.fetch(FetchDescriptor<TagV3>()) where tag.author == nil {
///         tag.author = defaultAuthor
///     }
/// }
/// ```
public struct CustomOperation: MigrationOperation {
    public let description: String
    private let willBody: (@Sendable (ModelContext, MigrationStash) throws -> Void)?
    private let didBody:  (@Sendable (ModelContext, MigrationStash) throws -> Void)?

    /// Convenience: a `didMigrate`-only custom operation.
    public init(
        _ description: String,
        didMigrate: @escaping @Sendable (ModelContext) throws -> Void
    ) {
        self.description = description
        self.willBody = nil
        self.didBody = { context, _ in try didMigrate(context) }
    }

    /// The general form, with explicit phase closures and access to the stash.
    public init(
        _ description: String,
        willMigrate: (@Sendable (ModelContext, MigrationStash) throws -> Void)? = nil,
        didMigrate:  (@Sendable (ModelContext, MigrationStash) throws -> Void)? = nil
    ) {
        self.description = description
        self.willBody = willMigrate
        self.didBody = didMigrate
    }

    public func willMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        try willBody?(context, stash)
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        try didBody?(context, stash)
    }
}
