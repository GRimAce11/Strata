import SQLite3
public import Foundation
import StrataCore
public import SwiftData

/// Reads the on-disk shape of a SwiftData store and reports its tables,
/// columns, indexes, and version metadata.
///
/// ## Why this is separate from ``SchemaDiff``
///
/// `SchemaDiff` compares two **declared** `VersionedSchema` types. It
/// answers "what would changing my Swift types do to the schema?".
/// `StoreIntrospector` reads the **actual** sqlite database on a user's
/// device or in a test. It answers "what is the store *currently*
/// shaped like?". The two views together let you detect drift —
/// situations where a previous migration partially succeeded, or where
/// the user is running an older app version against a newer store.
public enum StoreIntrospector {

    /// Inspect the SwiftData store at `url` and return its actual shape.
    ///
    /// - Parameter url: Path to the primary `.store` file. The
    ///   accompanying `-wal` and `-shm` files are read implicitly by sqlite.
    /// - Throws: ``MigrationError/storeUnreadable(path:underlying:)`` on
    ///   sqlite open or read failure.
    public static func actualSchema(at url: URL) throws -> RuntimeSchema {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)

        guard rc == SQLITE_OK, let db else {
            let msg: String
            if let db {
                msg = String(cString: sqlite3_errmsg(db))
                sqlite3_close(db)
            } else {
                msg = "sqlite3_open_v2 returned code \(rc)"
            }
            throw MigrationError.storeUnreadable(
                path: url,
                underlying: SQLiteError(code: rc, message: msg)
            )
        }
        defer { sqlite3_close(db) }

        let tables  = try readTables(db: db)
        let indexes = try readIndexes(db: db)
        let version = readMetadataVersion(db: db)

        return RuntimeSchema(tables: tables, indexes: indexes, metadataVersion: version)
    }

    /// Compare a declared schema against the actual on-disk store and
    /// return a list of drift reasons. Returns an empty array when the
    /// store matches the declaration exactly.
    ///
    /// SwiftData stores entity `Foo` as table `ZFOO` and attribute
    /// `barBaz` as column `ZBARBAZ`. Drift is reported as missing or
    /// unexpected tables and missing attribute columns. Relationship
    /// columns and join tables are not checked (their shapes vary by
    /// cardinality and inverse configuration).
    public static func detectDrift(
        declared: any VersionedSchema.Type,
        at url: URL
    ) throws -> [String] {
        let actual = try actualSchema(at: url)
        let schema = Schema(versionedSchema: declared)
        var reasons: [String] = []

        // SwiftData entity tables are named Z + ENTITY_UPPERCASE (no underscore).
        // Z_ tables are system tables (Z_PRIMARYKEY, Z_METADATA, …).
        // Other non-Z tables (ACHANGE, ATRANSACTION, … from Core Data persistent
        // history; sqlite_* from SQLite internals) are also excluded.
        let userTables = actual.tables.filter {
            $0.name.hasPrefix("Z") && !$0.name.hasPrefix("Z_")
        }
        let actualTableNames = Set(userTables.map(\.name))

        let entityByTable = Dictionary(
            uniqueKeysWithValues: schema.entities.map { ("Z" + $0.name.uppercased(), $0) }
        )
        let expectedTableNames = Set(entityByTable.keys)

        for missing in expectedTableNames.subtracting(actualTableNames).sorted() {
            let entityName = entityByTable[missing]?.name ?? missing
            reasons.append("Missing table '\(missing)' for declared model '\(entityName)'")
        }
        for extra in actualTableNames.subtracting(expectedTableNames).sorted() {
            reasons.append("Unexpected table '\(extra)' has no matching declared model")
        }

        // Column-level drift: verify each declared attribute has a column.
        let systemColumns: Set<String> = ["Z_PK", "Z_ENT", "Z_OPT"]
        for (tableName, entity) in entityByTable {
            guard let table = actual.tables.first(where: { $0.name == tableName }) else { continue }
            let actualCols = Set(table.columns.map(\.name)).subtracting(systemColumns)
            for attrName in entity.attributesByName.keys.sorted() {
                let expectedCol = "Z" + attrName.uppercased()
                if !actualCols.contains(expectedCol) {
                    reasons.append("'\(tableName)': column '\(expectedCol)' missing for attribute '\(attrName)'")
                }
            }
        }

        return reasons
    }

    /// Placeholder preserved for source compatibility. No longer thrown
    /// by any implemented method.
    public enum Unimplemented: Error, CustomStringConvertible {
        case storeIntrospection

        public var description: String {
            "StoreIntrospector.Unimplemented.storeIntrospection is no longer active — " +
            "StoreIntrospector is fully implemented."
        }
    }
}

// MARK: - RuntimeSchema

/// A snapshot of the actual structure of a store at a moment in time.
public struct RuntimeSchema: Sendable, Equatable {
    public let tables: [Table]
    public let indexes: [Index]
    /// The store UUID from the `Z_METADATA` table, if present.
    public let metadataVersion: String?

    public struct Table: Sendable, Equatable {
        public let name: String
        public let columns: [Column]
    }

    public struct Column: Sendable, Equatable {
        public let name: String
        public let type: String
        public let isNullable: Bool
        public let isPrimaryKey: Bool
    }

    public struct Index: Sendable, Equatable {
        public let name: String
        public let table: String
        public let columns: [String]
        public let isUnique: Bool
    }
}

// MARK: - Private SQLite helpers

private extension StoreIntrospector {

    struct SQLiteError: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite error \(code): \(message)" }
    }

    static func readTables(db: OpaquePointer) throws -> [RuntimeSchema.Table] {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        return try queryRows(db: db, sql: sql) { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            let name = String(cString: ptr)
            let columns = try readColumns(db: db, tableName: name)
            return RuntimeSchema.Table(name: name, columns: columns)
        }
    }

    static func readColumns(db: OpaquePointer, tableName: String) throws -> [RuntimeSchema.Column] {
        let escaped = tableName.replacingOccurrences(of: "\"", with: "\"\"")
        let sql = "PRAGMA table_info(\"\(escaped)\")"
        // PRAGMA table_info columns: cid | name | type | notnull | dflt_value | pk
        return try queryRows(db: db, sql: sql) { stmt in
            guard let namePtr = sqlite3_column_text(stmt, 1) else { return nil }
            let name = String(cString: namePtr)
            let type: String
            if let typePtr = sqlite3_column_text(stmt, 2) {
                type = String(cString: typePtr)
            } else {
                type = ""
            }
            let isNotNull    = sqlite3_column_int(stmt, 3) != 0
            let isPrimaryKey = sqlite3_column_int(stmt, 5) != 0
            return RuntimeSchema.Column(
                name: name,
                type: type,
                isNullable: !isNotNull,
                isPrimaryKey: isPrimaryKey
            )
        }
    }

    static func readIndexes(db: OpaquePointer) throws -> [RuntimeSchema.Index] {
        let tableNames: [String] = try queryRows(
            db: db,
            sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ) { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: ptr)
        }

        var indexes: [RuntimeSchema.Index] = []
        for tableName in tableNames {
            let escaped = tableName.replacingOccurrences(of: "\"", with: "\"\"")
            // PRAGMA index_list columns: seq | name | unique | origin | partial
            let tableIndexes: [RuntimeSchema.Index] = try queryRows(
                db: db,
                sql: "PRAGMA index_list(\"\(escaped)\")"
            ) { stmt in
                guard let namePtr = sqlite3_column_text(stmt, 1) else { return nil }
                let indexName = String(cString: namePtr)
                let isUnique  = sqlite3_column_int(stmt, 2) != 0
                let cols      = try readIndexColumns(db: db, indexName: indexName)
                return RuntimeSchema.Index(
                    name: indexName,
                    table: tableName,
                    columns: cols,
                    isUnique: isUnique
                )
            }
            indexes.append(contentsOf: tableIndexes)
        }
        return indexes
    }

    static func readIndexColumns(db: OpaquePointer, indexName: String) throws -> [String] {
        let escaped = indexName.replacingOccurrences(of: "\"", with: "\"\"")
        // PRAGMA index_info columns: seqno | cid | name
        let sql = "PRAGMA index_info(\"\(escaped)\")"
        return try queryRows(db: db, sql: sql) { stmt in
            guard let ptr = sqlite3_column_text(stmt, 2) else { return nil }
            return String(cString: ptr)
        }
    }

    static func readMetadataVersion(db: OpaquePointer) -> String? {
        // Z_METADATA is the Core Data / SwiftData metadata table.
        // Z_UUID is a stable UUID string that identifies the store instance.
        let mapper: (OpaquePointer) -> String? = { stmt in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: ptr)
        }
        guard let rows = try? queryRows(db: db, sql: "SELECT Z_UUID FROM Z_METADATA LIMIT 1", rowMapper: mapper) else {
            return nil
        }
        return rows.first
    }

    /// Prepares `sql`, iterates all rows, maps each via `rowMapper`, and
    /// returns the non-nil results. Uses a single prepared statement that
    /// is finalized on return — safe to call recursively since each call
    /// owns its own `OpaquePointer` statement handle.
    static func queryRows<T>(
        db: OpaquePointer,
        sql: String,
        rowMapper: (OpaquePointer) throws -> T?
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError(code: sqlite3_errcode(db), message: "prepare failed — \(errMsg)")
        }
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let value = try rowMapper(stmt) {
                results.append(value)
            }
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError(code: step, message: "step failed — \(errMsg)")
        }
        return results
    }
}
