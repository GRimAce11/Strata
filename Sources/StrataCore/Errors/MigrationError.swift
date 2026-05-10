import Foundation

/// Errors thrown by Strata's migration pipeline.
///
/// All errors carry enough context for the caller to either recover (using
/// the rollback machinery in ``SafeModelContainer``) or surface a useful
/// diagnostic to the end user.
public enum MigrationError: Error, Sendable, CustomStringConvertible {

    /// A required source value was missing during a `Rename` operation.
    /// Always indicates a bug in the migration plan or unexpected store state.
    case renameStashMissing(model: String, property: String)

    /// An operation could not locate a persistent model by its identifier
    /// after the schema transition (typically because the entity was deleted).
    case persistentIDNotFound(model: String)

    /// An `Assert.noNulls` post-condition failed.
    case nullsAfterMigration(model: String, property: String, count: Int)

    /// An `Assert.unique` post-condition failed.
    case duplicatesAfterMigration(model: String, property: String, duplicateCount: Int)

    /// A user-supplied `Assert.custom` post-condition failed.
    case customAssertionFailed(name: String, message: String?)

    /// Failed to copy the store to a backup location prior to migration.
    case backupFailed(underlying: any Error, path: URL)

    /// Failed to restore the store from backup after a migration failure.
    case rollbackFailed(underlying: any Error, attemptedRestoreFrom: URL)

    /// The migration itself failed; if `backupAvailableAt` is non-nil the
    /// original store has been restored at the canonical location and the
    /// caller may choose what to do next.
    case migrationFailed(underlying: any Error, backupAvailableAt: URL?)

    /// Validation found a problem before the migration ran. Migration was
    /// skipped; no changes were made to the store.
    case validationFailed(reasons: [String])

    /// The on-disk store schema and the declared `VersionedSchema` disagree.
    /// This usually means a prior migration partially completed or was
    /// performed by a non-Strata-aware code path.
    case schemaDrift(reasons: [String])

    /// The store file at the given URL is not in a readable SwiftData store
    /// format. This is the closest Strata gets to "corruption" — we do not
    /// repair, only surface.
    case storeUnreadable(path: URL, underlying: any Error)

    public var description: String {
        switch self {
        case .renameStashMissing(let model, let property):
            return "Rename stash missing for \(model).\(property). " +
                   "Did willMigrate run? Did the source entity exist?"
        case .persistentIDNotFound(let model):
            return "Persistent identifier not found for model \(model) after migration."
        case .nullsAfterMigration(let model, let property, let count):
            return "Assert.noNulls failed: \(count) row(s) have nil \(model).\(property) after migration."
        case .duplicatesAfterMigration(let model, let property, let dups):
            return "Assert.unique failed: \(dups) duplicate value(s) for \(model).\(property) after migration."
        case .customAssertionFailed(let name, let message):
            return "Assertion '\(name)' failed: \(message ?? "no message")"
        case .backupFailed(let err, let path):
            return "Backup failed for \(path.path): \(err)"
        case .rollbackFailed(let err, let from):
            return "Rollback failed (attempted restore from \(from.path)): \(err)"
        case .migrationFailed(let err, let backup):
            let suffix = backup.map { " (backup at: \($0.path))" } ?? ""
            return "Migration failed: \(err)\(suffix)"
        case .validationFailed(let reasons):
            return "Plan validation failed:\n - " + reasons.joined(separator: "\n - ")
        case .schemaDrift(let reasons):
            return "Schema drift detected:\n - " + reasons.joined(separator: "\n - ")
        case .storeUnreadable(let path, let err):
            return "Store unreadable at \(path.path): \(err)"
        }
    }
}
