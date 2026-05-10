import Foundation
import SwiftData

/// Post-condition checks that run after all other operations in a stage.
///
/// Assertions throw ``MigrationError`` on failure. With Strata's
/// ``SafeModelContainer/Safety/backupAndRollback`` mode active, a thrown
/// assertion triggers a rollback to the pre-migration backup — the user
/// never sees the half-migrated store.
///
/// Use ``Assert`` to encode invariants that *must* hold after migration:
/// non-null required fields, unique values, expected row counts. These
/// are the most valuable lines in any migration plan when a migration
/// regresses six months later.
public enum Assert {

    /// Assert that no entity has a `nil` value for the given optional
    /// property after migration.
    ///
    /// Typical use: a column transitioning from optional to non-optional
    /// in the next schema version — you want to be sure the backfill
    /// you wrote actually covered every row.
    public static func noNulls<M: PersistentModel, V>(
        _ keyPath: KeyPath<M, V?>
    ) -> some MigrationOperation {
        NoNullsAssertion(keyPath: keyPath)
    }

    /// Assert that every entity has a distinct value for the given
    /// property. Pair this with a `@Attribute(.unique)` declaration to
    /// catch migrations that violate uniqueness *before* the next save
    /// makes the store unrecoverable.
    public static func unique<M: PersistentModel, V: Hashable & Sendable>(
        _ keyPath: KeyPath<M, V>
    ) -> some MigrationOperation {
        UniqueAssertion(keyPath: keyPath)
    }

    /// Assert that the entity count matches a predicate after migration.
    /// Often the easiest way to express "we did not silently drop rows":
    /// pass the row count you captured in `willMigrate` via a
    /// ``CustomOperation``, or assert against an absolute floor.
    public static func count<M: PersistentModel>(
        of model: M.Type,
        satisfies: @escaping @Sendable (Int) -> Bool,
        message: String? = nil
    ) -> some MigrationOperation {
        CountAssertion(modelName: String(describing: model), fetch: { ctx in
            try ctx.fetchCount(FetchDescriptor<M>())
        }, predicate: satisfies, message: message)
    }

    /// A free-form assertion. The closure runs in `didMigrate`; return
    /// `true` to pass. The optional `message` is surfaced on failure.
    public static func custom(
        _ name: String,
        message: String? = nil,
        check: @escaping @Sendable (ModelContext) throws -> Bool
    ) -> some MigrationOperation {
        CustomAssertion(name: name, message: message, check: check)
    }
}

// MARK: - Internals

private struct NoNullsAssertion<M: PersistentModel, V>: MigrationOperation, @unchecked Sendable {
    let keyPath: KeyPath<M, V?>
    var description: String { "Assert noNulls \(M.self).\(_strataPropertyName(keyPath))" }
    var phase: MigrationPhase { .assertions }

    func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        let nilCount = try context.fetch(FetchDescriptor<M>())
            .lazy.filter { $0[keyPath: keyPath] == nil }.count
        if nilCount > 0 {
            throw MigrationError.nullsAfterMigration(
                model: String(describing: M.self),
                property: _strataPropertyName(keyPath),
                count: nilCount
            )
        }
    }
}

private struct UniqueAssertion<M: PersistentModel, V: Hashable & Sendable>: MigrationOperation, @unchecked Sendable {
    let keyPath: KeyPath<M, V>
    var description: String { "Assert unique \(M.self).\(_strataPropertyName(keyPath))" }
    var phase: MigrationPhase { .assertions }

    func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        var seen = Set<V>()
        var duplicates = 0
        for object in try context.fetch(FetchDescriptor<M>()) {
            if !seen.insert(object[keyPath: keyPath]).inserted {
                duplicates += 1
            }
        }
        if duplicates > 0 {
            throw MigrationError.duplicatesAfterMigration(
                model: String(describing: M.self),
                property: _strataPropertyName(keyPath),
                duplicateCount: duplicates
            )
        }
    }
}

private struct CountAssertion: MigrationOperation {
    let modelName: String
    let fetch: @Sendable (ModelContext) throws -> Int
    let predicate: @Sendable (Int) -> Bool
    let message: String?
    var description: String { "Assert count(\(modelName)) satisfies predicate" }
    var phase: MigrationPhase { .assertions }

    func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        let count = try fetch(context)
        if !predicate(count) {
            throw MigrationError.customAssertionFailed(
                name: description,
                message: message ?? "count = \(count)"
            )
        }
    }
}

private struct CustomAssertion: MigrationOperation {
    let name: String
    let message: String?
    let check: @Sendable (ModelContext) throws -> Bool
    var description: String { "Assert \(name)" }
    var phase: MigrationPhase { .assertions }

    func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        if try check(context) == false {
            throw MigrationError.customAssertionFailed(name: name, message: message)
        }
    }
}
