import Foundation

/// Copies a SwiftData store (and its `-wal` / `-shm` companions) to a
/// sibling backup directory, and restores from one on rollback.
///
/// SwiftData stores are sqlite databases. The store URL points to the
/// primary `.store` file, but at runtime sqlite may have written changes
/// to a write-ahead log (`-wal`) or shared-memory file (`-shm`) that
/// must be carried along for the backup to be coherent.
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
            for url in storeAndCompanions() where FileManager.default.fileExists(atPath: url.path) {
                let dest = dir.appending(path: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
            }
            StrataLog.safety.notice("Backup created at \(dir.path, privacy: .public)")
            return dir
        } catch {
            // Clean up partial backup on failure
            try? FileManager.default.removeItem(at: dir)
            throw MigrationError.backupFailed(underlying: error, path: storeURL)
        }
    }

    /// Restore the store from a previously-created backup directory.
    /// Deletes any current `.store` / `-wal` / `-shm` first.
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
            at: backupRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(daysToKeep) * 86_400)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
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
