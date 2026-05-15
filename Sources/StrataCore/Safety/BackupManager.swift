import Foundation

/// Copies a SwiftData store to a sibling backup directory and restores
/// from one on rollback.
///
/// Backup uses ``SQLiteStoreBackup`` (the sqlite3 online backup API) rather
/// than a raw filesystem copy. This guarantees a WAL-consistent snapshot:
/// the destination is a clean, WAL-free `.store` file that contains all
/// committed transactions from the source, regardless of whether a `-wal`
/// file was present at copy time.
package struct BackupManager {

    /// Where backups are placed: a sibling directory of the store named
    /// `.strata-backups/`. Each backup is a timestamped subdirectory.
    package let backupRoot: URL
    package let storeURL: URL

    package init(storeURL: URL) {
        self.storeURL = storeURL
        self.backupRoot = storeURL
            .deletingLastPathComponent()
            .appending(path: ".strata-backups", directoryHint: .isDirectory)
    }

    package func makeBackup() throws -> URL {
        try FileManager.default.createDirectory(
            at: backupRoot, withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = backupRoot.appending(path: "backup-\(stamp)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        do {
            // Use the SQLite online backup API for a WAL-consistent snapshot.
            // Produces a single, clean .store file — no WAL/SHM companion needed.
            let dest = dir.appending(path: storeURL.lastPathComponent)
            try SQLiteStoreBackup.copy(from: storeURL, to: dest)
            StrataLog.safety.notice("Backup created at \(dir.path, privacy: .public)")
            return dir
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw MigrationError.backupFailed(underlying: error, path: storeURL)
        }
    }

    /// Restore the store from a previously-created backup directory.
    /// Deletes any current `.store` / `-wal` / `-shm` first so the restored
    /// state starts clean.
    package func restore(from backupDir: URL) throws {
        do {
            for url in storeAndCompanions() {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            for url in try FileManager.default.contentsOfDirectory(
                at: backupDir, includingPropertiesForKeys: nil
            ) {
                let dest = storeURL.deletingLastPathComponent().appending(path: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
            }
            StrataLog.safety.notice("Restored store from \(backupDir.path, privacy: .public)")
        } catch {
            throw MigrationError.rollbackFailed(underlying: error, attemptedRestoreFrom: backupDir)
        }
    }

    /// Best-effort: remove backups older than `daysToKeep` days.
    /// Called after a successful migration to bound disk usage.
    package func pruneOlderThan(daysToKeep: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(daysToKeep) * 86_400)
        for entry in entries {
            // Creation date is stable — backup dirs are written once and never
            // modified in place, so modification date can drift on APFS.
            let values = try? entry.resourceValues(forKeys: [.creationDateKey])
            if let created = values?.creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private func storeAndCompanions() -> [URL] {
        let base = storeURL.deletingPathExtension()
        let ext = storeURL.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        return [
            base.appendingPathExtension(ext.isEmpty ? "store" : ext),
            URL(fileURLWithPath: base.path + suffix + "-wal"),
            URL(fileURLWithPath: base.path + suffix + "-shm"),
        ]
    }
}
