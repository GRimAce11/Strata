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
#endif // os(macOS)
