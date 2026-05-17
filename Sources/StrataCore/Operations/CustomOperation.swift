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
/// ## Controlling execution phase
///
/// By default `CustomOperation` runs in `.body` — after all `Rename`
/// captures and before assertions. Supply `phase: .captures` to run
/// alongside (and before) `Rename` captures, or `phase: .assertions` to
/// run as a post-condition check after all writes are complete.
///
/// ```swift
/// // Count rows before migration to verify nothing was dropped
/// var rowCountBefore = 0
/// CustomOperation("Snapshot row count", phase: .captures) { ctx, stash in
///     rowCountBefore = try ctx.fetchCount(FetchDescriptor<PostV2>())
///     stash.set("rowCount", rowCountBefore)
/// }
/// Assert.custom("row count unchanged") { ctx in
///     let after = try ctx.fetchCount(FetchDescriptor<PostV3>())
///     return after == rowCountBefore
/// }
/// ```
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
    public let phase: MigrationPhase
    private let willBody: (@Sendable (ModelContext, MigrationStash) throws -> Void)?
    private let didBody:  (@Sendable (ModelContext, MigrationStash) throws -> Void)?

    /// Convenience: a `didMigrate`-only custom operation.
    ///
    /// - Parameters:
    ///   - description: Short human-readable label for logs and reports.
    ///   - phase: Execution phase. Default is `.body` (runs after captures,
    ///     before assertions). Use `.captures` to run before `Rename`, or
    ///     `.assertions` to run as a post-condition.
    ///   - didMigrate: Closure that runs in `didMigrate` with the
    ///     destination-schema `ModelContext`.
    public init(
        _ description: String,
        phase: MigrationPhase = .body,
        didMigrate: @escaping @Sendable (ModelContext) throws -> Void
    ) {
        self.description = description
        self.phase = phase
        self.willBody = nil
        self.didBody = { context, _ in try didMigrate(context) }
    }

    /// The general form, with explicit phase closures and access to the stash.
    ///
    /// - Parameters:
    ///   - description: Short human-readable label for logs and reports.
    ///   - phase: Execution phase. Default is `.body`.
    ///   - willMigrate: Optional closure for the source-schema phase.
    ///   - didMigrate: Optional closure for the destination-schema phase.
    public init(
        _ description: String,
        phase: MigrationPhase = .body,
        willMigrate: (@Sendable (ModelContext, MigrationStash) throws -> Void)? = nil,
        didMigrate:  (@Sendable (ModelContext, MigrationStash) throws -> Void)? = nil
    ) {
        self.description = description
        self.phase = phase
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
