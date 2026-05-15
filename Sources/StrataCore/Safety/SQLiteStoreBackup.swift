import SQLite3
import Foundation

/// Copies a SQLite database using the official online backup API.
///
/// Unlike a raw filesystem copy, `sqlite3_backup_*` reads the committed
/// state of the source database — including any outstanding Write-Ahead Log
/// (WAL) frames — into a clean, WAL-free destination file. The source can
/// be an open live store; the backup sees only fully committed transactions.
package enum SQLiteStoreBackup {

    package enum BackupError: Error, CustomStringConvertible {
        case cannotOpenSource(URL, Int32)
        case cannotOpenDestination(URL, Int32)
        case initFailed(String)
        case stepFailed(Int32, String)

        package var description: String {
            switch self {
            case .cannotOpenSource(let url, let code):
                return "Cannot open source store at \(url.path) (sqlite error \(code))"
            case .cannotOpenDestination(let url, let code):
                return "Cannot open destination at \(url.path) (sqlite error \(code))"
            case .initFailed(let msg):
                return "sqlite3_backup_init failed: \(msg)"
            case .stepFailed(let code, let msg):
                return "sqlite3_backup_step failed with code \(code): \(msg)"
            }
        }
    }

    /// Copy the committed state of `source` into `destination` atomically.
    ///
    /// - Parameters:
    ///   - source: Path to the primary `.store` file. The `-wal` and `-shm`
    ///     companions are read implicitly by SQLite if present.
    ///   - destination: Output path. Created if it does not exist; overwritten
    ///     if it does.
    package static func copy(from source: URL, to destination: URL) throws {
        var srcDB: OpaquePointer?
        let openRC = sqlite3_open_v2(
            source.path, &srcDB,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openRC == SQLITE_OK, let srcDB else {
            sqlite3_close(srcDB)
            throw BackupError.cannotOpenSource(source, openRC)
        }
        defer { sqlite3_close(srcDB) }

        var dstDB: OpaquePointer?
        let createRC = sqlite3_open(destination.path, &dstDB)
        guard createRC == SQLITE_OK, let dstDB else {
            sqlite3_close(dstDB)
            throw BackupError.cannotOpenDestination(destination, createRC)
        }
        defer { sqlite3_close(dstDB) }

        guard let backup = sqlite3_backup_init(dstDB, "main", srcDB, "main") else {
            let msg = String(cString: sqlite3_errmsg(dstDB))
            throw BackupError.initFailed(msg)
        }
        defer { sqlite3_backup_finish(backup) }

        // -1 copies all pages in a single step; fine for migration-time use.
        let stepRC = sqlite3_backup_step(backup, -1)
        guard stepRC == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(dstDB))
            throw BackupError.stepFailed(stepRC, msg)
        }
    }
}
