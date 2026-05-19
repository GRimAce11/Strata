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
    ///   - cloudKitDatabase: CloudKit database for the primary store. Pass
    ///     `.private("iCloud.com.example.MyApp")` or `.automatic` if the
    ///     store is iCloud-synced; omit (`nil`, the default) for a
    ///     local-only store.
    ///
    ///     When non-nil, safety is automatically capped at
    ///     ``Safety/backupOnly`` — rolling back a CloudKit store risks iCloud
    ///     sync conflicts because schema changes may already have been
    ///     propagated to the cloud before rollback runs. The local backup is
    ///     still retained for manual recovery.
    ///   - configurations: Additional `ModelConfiguration` values passed
    ///     straight through to SwiftData (e.g. for sharing). The primary
    ///     configuration is built from `schema`, `storeURL`, and
    ///     `cloudKitDatabase`.
    @discardableResult
    public static func make(
        for schema: Schema,
        plan: MigrationPlan,
        storeURL: URL,
        safety: Safety = .backupAndRollback,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase? = nil,
        configurations: [ModelConfiguration] = []
    ) async throws -> ModelContainer {

        let startedAt = Date()

        // 0. Crash recovery — check for an incomplete migration from a prior
        //    launch (crash, jetsam, power loss) and restore from backup if found.
        //    Must run before any new migration state is written.
        try MigrationRecoveryCoordinator(storeURL: storeURL).checkAndRecover()

        // 1. Static validation — cheap, runs before touching the store.
        let validationErrors = plan.validate()
        if !validationErrors.isEmpty {
            throw MigrationError.validationFailed(reasons: validationErrors)
        }

        // 2. CloudKit safety cap: rolling back a CloudKit-synced store risks
        //    sync conflicts because SwiftData may have already propagated the
        //    schema change to iCloud before the local rollback runs. Cap at
        //    .backupOnly so the backup is retained for manual recovery, but
        //    automatic store replacement is skipped.
        //    Note: Optional<CloudKitDatabase> != nil does not require Equatable.
        let isCloudKit = cloudKitDatabase != nil
        let effectiveSafety: Safety
        if isCloudKit && safety == .backupAndRollback {
            StrataLog.safety.warning(
                "[Strata] CloudKit store detected — downgrading safety from .backupAndRollback to .backupOnly. Rolling back a CloudKit-synced store risks iCloud sync conflicts; the backup is kept if migration fails."
            )
            effectiveSafety = .backupOnly
        } else {
            effectiveSafety = safety
        }

        // 3. Snapshot the store's schema version (Z_VERSION integer) to detect
        //    whether migration runs, AND read the human-readable version identifier
        //    from Z_PLIST so HookContext.sourceVersion reflects the store's actual
        //    current schema rather than always showing the plan's first stage.
        let schemaVersionBefore = SQLiteStoreBackup.readSchemaVersion(at: storeURL)
        let sourceVersion: String = {
            let ids = SQLiteStoreBackup.readModelVersionIdentifiers(at: storeURL)
            return ids?.first ?? plan.stages.first.map { String(describing: $0.fromSchema) } ?? "?"
        }()
        let destinationVersion = plan.stages.last.map { String(describing: $0.toSchema) } ?? "?"

        // 4. Optional backup. makeBackup() returns nil on first launch
        //    (store doesn't exist yet) — nothing to back up.
        let backup: URL?
        if effectiveSafety != .none {
            backup = try BackupManager(storeURL: storeURL).makeBackup()
        } else {
            backup = nil
        }

        // 5. Journal — record migration start. This entry is the crash-detection
        //    anchor: if the process dies before migrationCompleted is written,
        //    the next launch's MigrationRecoveryCoordinator will find an
        //    incomplete planID and auto-restore.
        let planID = UUID().uuidString
        let journal = MigrationJournal(storeURL: storeURL)
        journal.append(.migrationStarted(
            planID: planID,
            fromVersion: sourceVersion,
            toVersion: destinationVersion,
            storeFile: storeURL.lastPathComponent
        ))
        if let backup {
            journal.append(.backupCreated(planID: planID, backupPath: backup.path))
        }

        // 6. Pre-migration hook.
        if let pre = plan.preMigration {
            let ctx = MigrationPlan.HookContext(
                storeURL: storeURL,
                sourceVersion: sourceVersion,
                destinationVersion: destinationVersion
            )
            try pre(ctx)
        }

        // 7. Build the SwiftData-native plan and container.
        //    SwiftData requires a SchemaMigrationPlan-conforming TYPE (not a
        //    value), so we install runtime stages into the static bridge for
        //    the duration of ModelContainer.init. MigrationRuntime serializes
        //    this via actor isolation — only one migration can hold the bridge
        //    slot at a time; others wait in the actor queue.
        let appleStages = SchemaMigrationPlanFactory.stages(for: plan)
        let primary = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: cloudKitDatabase ?? .none)

        // Strip any caller-supplied configuration whose URL matches storeURL.
        // Passing two configurations for the same store causes undefined
        // behaviour in SwiftData. Log a warning so the caller knows.
        let extraConfigurations = configurations.filter { $0.url != storeURL }
        if extraConfigurations.count != configurations.count {
            let dropped = configurations.count - extraConfigurations.count
            StrataLog.safety.warning(
                "[Strata] Dropped \(dropped, privacy: .public) configuration(s) whose URL matched storeURL — the primary store configuration is added automatically."
            )
        }

        let container: ModelContainer
        do {
            // Actor-serialized: concurrent migrations on different stores
            // queue here rather than racing to overwrite each other's stages.
            container = try await MigrationRuntime.shared.perform(
                schemas: plan.schemas,
                stages: appleStages,
                _MigrationWorkBox {
                    try ModelContainer(
                        for: schema,
                        migrationPlan: _StrataAppleBridgePlan.self,
                        configurations: [primary] + extraConfigurations
                    )
                }
            )
        } catch {
            // Migration itself failed — write rollback journal entries, then
            // restore from backup if safety level allows.
            journal.append(.rollbackStarted(
                planID: planID,
                reason: "migration failed: \(error)"
            ))
            if effectiveSafety == .backupAndRollback, let backup {
                StrataLog.safety.error(
                    "[Strata] Migration failed; rolling back from \(backup.path, privacy: .public)"
                )
                try BackupManager(storeURL: storeURL).restore(from: backup)
            }
            journal.append(.rollbackCompleted(planID: planID))
            throw MigrationError.migrationFailed(underlying: error, backupAvailableAt: backup)
        }

        // 8. Determine whether migration actually ran by comparing the schema
        //    version. If the store was already at the correct version, remove
        //    the backup we made — no point accumulating one per launch.
        let schemaVersionAfter = SQLiteStoreBackup.readSchemaVersion(at: storeURL)
        let migrationRan = schemaVersionBefore == nil || schemaVersionBefore != schemaVersionAfter

        if let backup {
            if migrationRan {
                StrataLog.safety.notice(
                    "[Strata] Migration succeeded for \(storeURL.lastPathComponent, privacy: .public)"
                )
                BackupManager(storeURL: storeURL).pruneOlderThan(daysToKeep: 7)
            } else {
                // No migration ran — the store was already current. Discard the
                // tentative backup so we don't accumulate one per launch.
                try? FileManager.default.removeItem(at: backup)
                StrataLog.safety.notice(
                    "[Strata] No migration needed for \(storeURL.lastPathComponent, privacy: .public); tentative backup discarded"
                )
            }
        }

        // 9. Journal — record completion. This is what MigrationRecoveryCoordinator
        //    looks for on the next launch to confirm the migration finished cleanly.
        let durationMs = Int64(Date().timeIntervalSince(startedAt) * 1000)
        journal.append(.migrationCompleted(
            planID: planID,
            durationMs: durationMs,
            migrationRan: migrationRan
        ))

        // 10. Post-migration hook. Runs AFTER the rollback window has closed.
        //     A failure here does NOT trigger store rollback — the migration
        //     already succeeded and the store is consistent. Throw a distinct
        //     error so callers can handle hook failures separately.
        if let post = plan.postMigration {
            let ctx = MigrationPlan.HookContext(
                storeURL: storeURL,
                sourceVersion: sourceVersion,
                destinationVersion: destinationVersion
            )
            do {
                try post(ctx)
            } catch {
                StrataLog.safety.error(
                    "[Strata] postMigration hook failed (migration succeeded): \(error, privacy: .public)"
                )
                throw MigrationError.postMigrationHookFailed(
                    underlying: error,
                    backupAvailableAt: migrationRan ? backup : nil
                )
            }
        }

        return container
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
            // Always clean up the temp directory — success or failure.
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let copyURL = tmpDir.appending(path: storeURL.lastPathComponent)

            // Use the SQLite online backup API for a WAL-consistent copy.
            // Unlike a raw file copy, this reads the committed state of the
            // live store correctly even when a -wal file is present.
            try SQLiteStoreBackup.copy(from: storeURL, to: copyURL)

            _ = try await make(
                for: schema,
                plan: plan,
                storeURL: copyURL,
                safety: .none
            )
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
