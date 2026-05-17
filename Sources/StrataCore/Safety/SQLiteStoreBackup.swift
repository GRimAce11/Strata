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

    /// Read the `Z_VERSION` integer from `Z_METADATA`.
    ///
    /// SwiftData increments this value when a migration changes the store's
    /// schema. Comparing the value before and after `ModelContainer` init
    /// tells us whether migration actually ran — without which we'd back up
    /// the store on every launch, even when no migration is needed.
    ///
    /// Returns `nil` if the file doesn't exist, can't be opened, or has no
    /// `Z_METADATA` table (e.g. a freshly-created, not-yet-opened store).
    package static func readSchemaVersion(at url: URL) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT Z_VERSION FROM Z_METADATA LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Read the `NSStoreModelVersionIdentifiers` array from the binary plist
    /// stored in `Z_METADATA.Z_PLIST`.
    ///
    /// SwiftData writes the current schema's `VersionedSchema.versionIdentifier`
    /// string(s) here. This gives us the store's actual "current schema version"
    /// for the `HookContext.sourceVersion` field — far more meaningful than
    /// the plan's first-stage schema name, which is often many versions behind
    /// the store's real state.
    ///
    /// Returns `nil` if the store can't be opened, has no `Z_METADATA`, or the
    /// plist is missing or malformed.
    package static func readModelVersionIdentifiers(at url: URL) -> [String]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_PLIST FROM Z_METADATA LIMIT 1", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let byteCount = sqlite3_column_bytes(stmt, 0)
        guard byteCount > 0, let rawPtr = sqlite3_column_blob(stmt, 0) else { return nil }
        let data = Data(bytes: rawPtr, count: Int(byteCount))

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let identifiers = dict["NSStoreModelVersionIdentifiers"] as? [String] else { return nil }
        return identifiers.filter { !$0.isEmpty }
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
