import Foundation
import SwiftData

/// The primary entry point for running a Strata-managed migration.
///
/// `SafeModelContainer.make(...)` is a drop-in replacement for
/// `ModelContainer(for:migrationPlan:configurations:)` that adds:
///
/// - Automatic backup of the store before migration.
/// - Optional automatic rollback if migration throws.
/// - Plan validation before migration begins.
/// - Pre/post hooks defined on the plan.
/// - Structured ``MigrationError`` reporting.
///
/// The returned `ModelContainer` is identical to what SwiftData would have
/// produced on its own — Strata's machinery is invisible at the app's
/// data-access layer.
public enum SafeModelContainer {

    /// Determines what Strata does when migration fails.
    public enum Safety: Sendable, Equatable {
        /// Run the migration with no Strata-side safety net. Failures
        /// throw, the store is left in whatever state SwiftData wrote.
        /// Use this only in tests that explicitly want to observe
        /// partial state.
        case none

        /// Take a backup before migration, keep it on success, and do not
        /// roll back on failure. Useful when you would rather surface the
        /// failure to the user and let them choose what to do.
        case backupOnly

        /// Take a backup before migration. If migration throws, restore
        /// the store from the backup so the next launch starts from a
        /// known-good state. The default.
        case backupAndRollback
    }

    /// Run the migration described by `plan` and return a container open
    /// at the destination schema.
    ///
    /// - Parameters:
    ///   - schema: The current (destination) `Schema`, typically built
    ///     from the latest `VersionedSchema`.
    ///   - plan: A Strata ``MigrationPlan``.
    ///   - storeURL: Filesystem URL of the SwiftData store.
    ///   - safety: Backup/rollback behavior. Defaults to
    ///     ``Safety/backupAndRollback``.
    ///   - configurations: Additional `ModelConfiguration` values
    ///     passed straight through to SwiftData (e.g. for sharing or
    ///     CloudKit). The primary configuration is constructed from
    ///     `schema` + `storeURL`.
    @discardableResult
    public static func make(
        for schema: Schema,
        plan: MigrationPlan,
        storeURL: URL,
        safety: Safety = .backupAndRollback,
        configurations: [ModelConfiguration] = []
    ) async throws -> ModelContainer {

        // 1. Static validation. Cheap, runs before we touch the store.
        let validationErrors = plan.validate()
        if !validationErrors.isEmpty {
            throw MigrationError.validationFailed(reasons: validationErrors)
        }

        // 2. Optional backup.
        let backup = (safety != .none)
            ? try BackupManager(storeURL: storeURL).makeBackup()
            : nil

        // 3. Pre-migration hook.
        if let pre = plan.preMigration {
            let hookContext = MigrationPlan.HookContext(
                storeURL: storeURL,
                sourceVersion: plan.stages.first.map { String(describing: $0.fromSchema) } ?? "?",
                destinationVersion: plan.stages.last.map { String(describing: $0.toSchema) } ?? "?"
            )
            try pre(hookContext)
        }

        // 4. Build the SwiftData-native plan and container. SwiftData
        // requires a SchemaMigrationPlan-conforming TYPE, not a value, so
        // we install the runtime stages into a static bridge for the
        // duration of the ModelContainer init.
        let appleStages = SchemaMigrationPlanFactory.stages(for: plan)
        let primary = ModelConfiguration(schema: schema, url: storeURL)

        do {
            let container = try _StrataAppleBridge.shared.install(
                schemas: plan.schemas,
                stages: appleStages
            ) {
                try ModelContainer(
                    for: schema,
                    migrationPlan: _StrataAppleBridgePlan.self,
                    configurations: [primary] + configurations
                )
            }

            // 5. Post-migration hook.
            if let post = plan.postMigration {
                let hookContext = MigrationPlan.HookContext(
                    storeURL: storeURL,
                    sourceVersion: plan.stages.first.map { String(describing: $0.fromSchema) } ?? "?",
                    destinationVersion: plan.stages.last.map { String(describing: $0.toSchema) } ?? "?"
                )
                try post(hookContext)
            }

            // 6. Bound disk usage from backups.
            if safety != .none {
                BackupManager(storeURL: storeURL).pruneOlderThan(daysToKeep: 7)
            }

            StrataLog.safety.notice("Migration succeeded for \(storeURL.lastPathComponent, privacy: .public)")
            return container

        } catch {
            if safety == .backupAndRollback, let backup {
                StrataLog.safety.error("Migration failed; attempting rollback from \(backup.path, privacy: .public)")
                try BackupManager(storeURL: storeURL).restore(from: backup)
            }
            throw MigrationError.migrationFailed(
                underlying: error,
                backupAvailableAt: backup
            )
        }
    }

    /// Run a plan in "dry-run" mode: take a backup, copy the store into a
    /// throwaway location, run the migration against the copy, and
    /// report the outcome — leaving the original store untouched.
    ///
    /// Intended for ad-hoc safety checks ("will this migration succeed
    /// on the current user's store?"), not for automated testing — use
    /// ``StrataTesting`` for that.
    public static func dryRun(
        for schema: Schema,
        plan: MigrationPlan,
        storeURL: URL
    ) async -> DryRunResult {
        do {
            let tmpDir = FileManager.default.temporaryDirectory
                .appending(path: "strata-dryrun-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let copyURL = tmpDir.appending(path: storeURL.lastPathComponent)

            // Copy primary store (companions optional but recommended).
            for path in [storeURL,
                         URL(fileURLWithPath: storeURL.path + "-wal"),
                         URL(fileURLWithPath: storeURL.path + "-shm")]
                where FileManager.default.fileExists(atPath: path.path) {
                let dest = tmpDir.appending(path: path.lastPathComponent)
                try FileManager.default.copyItem(at: path, to: dest)
            }

            _ = try await make(
                for: schema,
                plan: plan,
                storeURL: copyURL,
                safety: .none
            )
            try? FileManager.default.removeItem(at: tmpDir)
            return .success
        } catch let error as MigrationError {
            return .failure(error)
        } catch {
            return .failure(.migrationFailed(underlying: error, backupAvailableAt: nil))
        }
    }
}

public enum DryRunResult: Sendable {
    case success
    case failure(MigrationError)

    public var isSuccess: Bool {
        if case .success = self { return true } else { return false }
    }
}
