internal import ArgumentParser
internal import Foundation
internal import StrataCore
internal import StrataInspect

@main
struct Strata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strata",
        abstract: "Inspect SwiftData stores and migration plans.",
        version: "0.1.0-dev",
        subcommands: [Inspect.self, Diff.self, Drift.self],
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

    func run() async throws {
        let url = URL(fileURLWithPath: storeURL)
        // Milestone 3 deferred: StoreIntrospector.actualSchema currently
        // throws Unimplemented. We surface a clear message rather than
        // pretending to work.
        do {
            let schema = try StoreIntrospector.actualSchema(at: url)
            print("Store: \(url.path)")
            print("Tables: \(schema.tables.count)")
            for table in schema.tables {
                print("  · \(table.name) (\(table.columns.count) columns)")
            }
        } catch let err as StoreIntrospector.Unimplemented {
            FileHandle.standardError.write(Data("\(err.description)\n".utf8))
            throw ExitCode(2)
        }
    }
}

// MARK: - strata diff

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Render a schema diff between two declared VersionedSchema types.",
        discussion: """
            This command is intended to be invoked from your test target or
            a tool target that has linked your app's schemas. It accepts the
            schema names via a programmatic API rather than the command line
            so we do not need to load Swift types from disk.

            See Documentation/CLI.md for usage.
            """
    )

    func run() async throws {
        let msg = "strata diff is not invokable directly from the command line. " +
                  "Use `SchemaDiff.diff(from:to:)` from your test target.\n"
        FileHandle.standardError.write(Data(msg.utf8))
        throw ExitCode(64)
    }
}

// MARK: - strata drift

struct Drift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drift",
        abstract: "Report drift between a declared schema and an on-disk store."
    )

    @Argument(help: "Path to the .store file to check.")
    var storeURL: String

    func run() async throws {
        let url = URL(fileURLWithPath: storeURL)
        do {
            _ = try StoreIntrospector.actualSchema(at: url)
            print("(no declared schema linked; drift detection requires schema metadata)")
        } catch let err as StoreIntrospector.Unimplemented {
            FileHandle.standardError.write(Data("\(err.description)\n".utf8))
            throw ExitCode(2)
        }
    }
}
