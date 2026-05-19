import Foundation

/// Detects and recovers from migrations that were interrupted by a crash,
/// jetsam kill, or power loss.
///
/// Call ``checkAndRecover()`` at the very start of ``SafeModelContainer/make``
/// — before any new migration state is written — so that a corrupt store from
/// a prior launch is always repaired before a new migration attempt begins.
///
/// ## Detection mechanism
///
/// The coordinator reads the ``MigrationJournal`` for the store and looks for
/// a `migrationStarted` entry with no subsequent `migrationCompleted` or
/// `rollbackCompleted`. If found, the previous migration session did not finish
/// cleanly.
///
/// ## Recovery strategy
///
/// If a pre-migration backup exists, the coordinator restores it and writes a
/// `crashRecoveryApplied` journal entry. If no backup is available (e.g. the
/// migration was running with `.safety = .none`), it logs an error and allows
/// SwiftData to open the potentially-inconsistent store — the store may be
/// unreadable, in which case SwiftData will surface its own error.
package struct MigrationRecoveryCoordinator: Sendable {

    package enum RecoveryResult: Sendable {
        /// Journal is clean — no interrupted migration detected.
        case noRecoveryNeeded
        /// An interrupted migration was detected and the store was restored
        /// from the most recent backup.
        case recoveredFromBackup(backupURL: URL)
        /// An interrupted migration was detected but no backup was available.
        /// The store may be in an inconsistent state.
        case noBackupAvailable(priorPlanID: String)
    }

    private let journal: MigrationJournal
    private let backupManager: BackupManager

    package init(storeURL: URL) {
        self.journal = MigrationJournal(storeURL: storeURL)
        self.backupManager = BackupManager(storeURL: storeURL)
    }

    /// Check for an incomplete prior migration and restore from backup if one
    /// is found. Safe to call on every launch — returns immediately when no
    /// recovery is needed.
    ///
    /// - Throws: ``MigrationError/rollbackFailed`` if a backup exists but the
    ///   restore operation itself fails.
    @discardableResult
    package func checkAndRecover() throws -> RecoveryResult {
        guard let incompletePlanID = journal.findIncompletePlanID() else {
            return .noRecoveryNeeded
        }

        StrataLog.safety.error(
            "[Strata] Incomplete migration detected (planID: \(incompletePlanID, privacy: .public)) — prior launch likely crashed mid-migration. Attempting recovery."
        )

        // Try the most recent backup
        if let latestBackup = backupManager.latestAvailableBackup() {
            StrataLog.safety.notice(
                "[Strata] Restoring from backup: \(latestBackup.path, privacy: .public)"
            )
            try backupManager.restore(from: latestBackup)

            journal.append(.crashRecoveryApplied(
                priorPlanID: incompletePlanID,
                restoredFrom: latestBackup.path
            ))

            StrataLog.safety.notice(
                "[Strata] Crash recovery complete — store restored to pre-migration state."
            )
            return .recoveredFromBackup(backupURL: latestBackup)
        }

        // No backup — log a fault and let SwiftData try to open the store.
        // SwiftData will surface its own error if the store is unreadable.
        StrataLog.safety.fault(
            "[Strata] Crash recovery failed — no backup found for incomplete migration (planID: \(incompletePlanID, privacy: .public)). Store may be inconsistent. Use safety: .backupAndRollback to enable automatic recovery."
        )
        return .noBackupAvailable(priorPlanID: incompletePlanID)
    }
}

// MARK: - BackupManager extension

extension BackupManager {
    /// Return the URL of the most recently created backup directory,
    /// or `nil` if the backup root does not exist or is empty.
    package func latestAvailableBackup() -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return nil }

        return entries
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.creationDateKey])
                guard let created = values?.creationDate else { return nil }
                return (url, created)
            }
            .sorted { $0.1 > $1.1 }   // most recent first
            .first?
            .0
    }
}
