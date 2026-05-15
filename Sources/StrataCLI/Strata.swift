// The strata CLI is a macOS-only tool. On other Apple platforms this
// file compiles to nothing; iOS/tvOS/watchOS/visionOS apps depend only
// on StrataCore and never link StrataCLI.
#if os(macOS)
internal import ArgumentParser
internal import Foundation
internal import StrataCore
internal import StrataInspect

@main
struct Strata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strata",
        abstract: "Inspect SwiftData stores and migration plans.",
        version: "0.1.0",
        subcommands: [Inspect.self, Diff.self, Drift.self, StoreDiff.self],
        defaultSubcommand: Inspect.self
    )
}

// MARK: - strata inspect

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Print a structural report for a SwiftData store on disk."
    )

    @Argument(help: "Path to the .store file to inspect.")
    var storeURL: String

    @Flag(name: .shortAndLong, help: "Show all columns for each table.")
    var verbose: Bool = false

    func run() async throws {
        let url = URL(fileURLWithPath: storeURL)
        let schema: RuntimeSchema
        do {
            schema = try StoreIntrospector.actualSchema(at: url)
        } catch {
            FileHandle.standardError.write(Data("strata inspect: \(error)\n".utf8))
            throw ExitCode(1)
        }

        print("Store: \(url.lastPathComponent)")
        if let uuid = schema.metadataVersion {
            print("UUID:  \(uuid)")
        }

        // SwiftData entity tables: Z + ENTITY_UPPERCASE, no underscore.
        // Z_ tables are SwiftData system tables; ACHANGE/ATRANSACTION/… are
        // persistent history tables. Both are treated as internal.
        let userTables   = schema.tables.filter { $0.name.hasPrefix("Z") && !$0.name.hasPrefix("Z_") }
        let systemTables = schema.tables.filter { !$0.name.hasPrefix("Z") || $0.name.hasPrefix("Z_") }

        print("\nModels (\(userTables.count)):")
        for table in userTables.sorted(by: { $0.name < $1.name }) {
            if verbose {
                print("  \(table.name)")
                for col in table.columns {
                    let flags = columnFlags(col)
                    print("    · \(col.name): \(col.type)\(flags.isEmpty ? "" : "  [\(flags)]")")
                }
            } else {
                let userCols = table.columns.filter { !["Z_PK", "Z_ENT", "Z_OPT"].contains($0.name) }
                print("  \(table.name)  (\(userCols.count) attribute column\(userCols.count == 1 ? "" : "s"))")
            }
        }

        if verbose && !systemTables.isEmpty {
            print("\nInternal tables (\(systemTables.count)):")
            for table in systemTables.sorted(by: { $0.name < $1.name }) {
                print("  \(table.name)  (\(table.columns.count) columns)")
            }
        }

        let userIndexes = schema.indexes.filter { !$0.name.hasPrefix("sqlite_") }
        if !userIndexes.isEmpty {
            print("\nIndexes (\(userIndexes.count)):")
            for index in userIndexes.sorted(by: { $0.name < $1.name }) {
                let unique = index.isUnique ? " UNIQUE" : ""
                print("  \(index.name)\(unique)")
                if verbose {
                    print("    ON \(index.table)(\(index.columns.joined(separator: ", ")))")
                }
            }
        }
    }

    private func columnFlags(_ col: RuntimeSchema.Column) -> String {
        var flags: [String] = []
        if col.isPrimaryKey { flags.append("PK") }
        if !col.isNullable  { flags.append("NOT NULL") }
        return flags.joined(separator: ", ")
    }
}

// MARK: - strata diff

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Render a schema diff between two declared VersionedSchema types.",
        discussion: """
            Programmatic entry point only — load your schemas in a tool target
            and call SchemaDiff.diff(from:to:) directly. See Documentation/CLI.md.
            """
    )

    func run() async throws {
        let msg = "strata diff is not invokable directly from the command line. " +
                  "Use `SchemaDiff.diff(from:to:)` from your tool or test target.\n"
        FileHandle.standardError.write(Data(msg.utf8))
        throw ExitCode(64)
    }
}

// MARK: - strata drift

struct Drift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drift",
        abstract: "Report drift between a declared schema and an on-disk store.",
        discussion: """
            Reads the on-disk store schema and prints the tables and columns found.
            To compare against a declared Swift schema, call
            StoreIntrospector.detectDrift(declared:at:) from your tool or test target.
            """
    )

    @Argument(help: "Path to the .store file to check.")
    var storeURL: String

    func run() async throws {
        let url = URL(fileURLWithPath: storeURL)
        let schema: RuntimeSchema
        do {
            schema = try StoreIntrospector.actualSchema(at: url)
        } catch {
            FileHandle.standardError.write(Data("strata drift: \(error)\n".utf8))
            throw ExitCode(1)
        }

        print("Store: \(url.lastPathComponent)")
        if let uuid = schema.metadataVersion {
            print("UUID:  \(uuid)")
        }

        let userTables = schema.tables.filter {
            $0.name.hasPrefix("Z") && !$0.name.hasPrefix("Z_")
        }
        print("\nOn-disk tables (\(userTables.count)):")
        for table in userTables.sorted(by: { $0.name < $1.name }) {
            let userCols = table.columns.filter { !["Z_PK", "Z_ENT", "Z_OPT"].contains($0.name) }
            print("  \(table.name)  (\(userCols.count) column\(userCols.count == 1 ? "" : "s"))")
            for col in userCols {
                print("    · \(col.name): \(col.type)")
            }
        }

        print("\nNote: to detect drift against a declared schema, call")
        print("      StoreIntrospector.detectDrift(declared:at:) from your Swift code.")
    }
}

// MARK: - strata store-diff

struct StoreDiff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store-diff",
        abstract: "Show structural differences between two SwiftData store files.",
        discussion: """
            Compares the on-disk schema of two store files and reports added,
            removed, and modified tables and columns. Useful for verifying
            that a migration changed exactly what you intended.
            """
    )

    @Argument(help: "Path to the first .store file (baseline).")
    var storeA: String

    @Argument(help: "Path to the second .store file (comparison).")
    var storeB: String

    func run() async throws {
        let urlA = URL(fileURLWithPath: storeA)
        let urlB = URL(fileURLWithPath: storeB)

        let schemaA: RuntimeSchema
        let schemaB: RuntimeSchema
        do {
            schemaA = try StoreIntrospector.actualSchema(at: urlA)
            schemaB = try StoreIntrospector.actualSchema(at: urlB)
        } catch {
            FileHandle.standardError.write(Data("strata store-diff: \(error)\n".utf8))
            throw ExitCode(1)
        }

        print("\(urlA.lastPathComponent)  →  \(urlB.lastPathComponent)")
        print(String(repeating: "─", count: 50))

        let tablesA = Dictionary(uniqueKeysWithValues: schemaA.tables.map { ($0.name, $0) })
        let tablesB = Dictionary(uniqueKeysWithValues: schemaB.tables.map { ($0.name, $0) })
        let allTables = Set(tablesA.keys).union(tablesB.keys).sorted()

        var hasChanges = false
        for name in allTables {
            switch (tablesA[name], tablesB[name]) {
            case (nil, let b?):
                print("+ \(name)  (\(b.columns.count) columns)")
                hasChanges = true
            case (_, nil):
                print("- \(name)")
                hasChanges = true
            case (let a?, let b?):
                let colsA = Dictionary(uniqueKeysWithValues: a.columns.map { ($0.name, $0) })
                let colsB = Dictionary(uniqueKeysWithValues: b.columns.map { ($0.name, $0) })
                let allCols = Set(colsA.keys).union(colsB.keys).sorted()
                var colChanges: [String] = []
                for col in allCols {
                    switch (colsA[col], colsB[col]) {
                    case (nil, let cb?): colChanges.append("  + \(cb.name): \(cb.type)")
                    case (_, nil):       colChanges.append("  - \(col)")
                    case (let ca?, let cb?) where ca.type != cb.type:
                        colChanges.append("  ~ \(col): \(ca.type) → \(cb.type)")
                    case (_, _): break  // unchanged
                    }
                }
                if !colChanges.isEmpty {
                    print("~ \(name)")
                    colChanges.forEach { print($0) }
                    hasChanges = true
                }
            default: break
            }
        }

        if !hasChanges {
            print("(no differences)")
        }
    }
}
#endif // os(macOS)
