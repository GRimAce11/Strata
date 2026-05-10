import Foundation
import SwiftData

/// A single, declaratively-specified piece of work inside a ``Stage``.
///
/// Operations execute in two phases, mirroring SwiftData's own
/// `MigrationStage.custom`:
///
/// - ``willMigrate(_:stash:)`` runs **before** SwiftData transforms the
///   store. The `ModelContext` is bound to the SOURCE schema, so you can
///   read values that would otherwise be lost. Stash anything you'll need
///   for `didMigrate` via the supplied ``MigrationStash``.
/// - ``didMigrate(_:stash:)`` runs **after** the schema has been
///   transformed. The `ModelContext` is bound to the DESTINATION schema.
///   This is where most write-side work happens.
///
/// Both methods have empty default implementations. Concrete operations
/// override only the phases they care about. ``Backfill``, for example,
/// only implements `didMigrate`; ``Rename`` implements both.
///
/// Strata calls operations in the order they appear inside a stage's
/// builder body. Renames are always staged first internally to guarantee
/// their captures happen before later operations might mutate the source.
public protocol MigrationOperation: Sendable {
    /// A short, human-readable summary used for logging and reports.
    /// Should not include the model name unless it would otherwise be
    /// ambiguous (Strata prefixes the model name automatically when
    /// rendering reports).
    var description: String { get }

    /// Sort priority within a stage. Lower values run first. Most
    /// operations should use the default. Renames use `.captures` so
    /// that subsequent operations see a consistent stash.
    var phase: MigrationPhase { get }

    /// Read-only work against the SOURCE schema.
    /// - Parameters:
    ///   - context: A `ModelContext` whose store still has the source
    ///     schema layout. Fetching against destination-schema types here
    ///     is undefined.
    ///   - stash: Use to pass captured values to `didMigrate`.
    func willMigrate(_ context: ModelContext, stash: MigrationStash) throws

    /// Write-side work against the DESTINATION schema.
    func didMigrate(_ context: ModelContext, stash: MigrationStash) throws
}

public extension MigrationOperation {
    func willMigrate(_ context: ModelContext, stash: MigrationStash) throws {}
    func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {}

    var phase: MigrationPhase { .body }
}

/// Internal sort buckets that guarantee operations execute in the right
/// order within a stage even if the user wrote them out of order.
public enum MigrationPhase: Int, Sendable, Comparable {
    /// Captures that must run before any other writes. ``Rename`` lives here.
    case captures = 0
    /// The main body of operations: ``Backfill``, ``Transform``, ``Delete``,
    /// ``CustomOperation``.
    case body = 100
    /// Post-conditions. All ``Assert`` operations live here.
    case assertions = 200

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
