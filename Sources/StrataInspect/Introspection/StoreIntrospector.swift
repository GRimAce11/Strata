public import Foundation
public import StrataCore
public import SwiftData

/// Reads the on-disk shape of a SwiftData store and reports its tables,
/// columns, indexes, and version metadata.
///
/// > Status: **scaffolded for Milestone 3.** The protocol surface and
/// > return types are stable; the body that opens the sqlite file and
/// > walks `sqlite_master` is not yet implemented. Calls currently
/// > throw ``Unimplemented`` so downstream code (e.g. ``StrataCLI``)
/// > can wire against the final API without ambiguity.
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

    /// Inspect the SwiftData store at `url` and return its actual
    /// shape.
    ///
    /// - Parameter url: Path to the primary `.store` file. The
    ///   accompanying `-wal` and `-shm` files are read implicitly by
    ///   sqlite.
    /// - Throws: ``Unimplemented`` (Milestone 3 placeholder),
    ///   ``MigrationError/storeUnreadable(path:underlying:)`` on
    ///   sqlite open failure.
    public static func actualSchema(at url: URL) throws -> RuntimeSchema {
        throw Unimplemented.storeIntrospection
    }

    /// Compare a declared schema against the actual on-disk store and
    /// return a list of drift reasons.
    public static func detectDrift(
        declared: any VersionedSchema.Type,
        at url: URL
    ) throws -> [String] {
        throw Unimplemented.storeIntrospection
    }

    public enum Unimplemented: Error, CustomStringConvertible {
        case storeIntrospection

        public var description: String {
            "StoreIntrospector is scaffolded for Milestone 3. " +
            "The sqlite introspection backend has not yet been implemented."
        }
    }
}

/// A snapshot of the actual structure of a store at a moment in time.
public struct RuntimeSchema: Sendable, Equatable {
    public let tables: [Table]
    public let indexes: [Index]
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
