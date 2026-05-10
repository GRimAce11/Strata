public import StrataCore
public import SwiftData
public import Foundation
internal import XCTest

/// Asserts that, after running a migration from a fixture, the
/// destination store's contents match a recorded JSON snapshot.
///
/// On first run (or when the snapshot file is missing), the helper
/// writes the current contents to disk and fails the test with a
/// "recorded" message so the developer must explicitly approve the
/// new snapshot by re-running.
///
/// Snapshot files live under a `__Snapshots__` directory next to the
/// test source file. The on-disk format is a stable, sorted JSON
/// document so diffs are reviewable in code review.
public func assertMigrationSnapshot<S: VersionedSchema>(
    fixture fixtureURL: URL,
    through finalSchema: S.Type,
    plan: MigrationPlan,
    matches snapshot: String,
    directory: URL? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let container = try await SafeModelContainer.make(
        for: Schema(versionedSchema: finalSchema),
        plan: plan,
        storeURL: fixtureURL,
        safety: .none
    )

    let actual = try snapshotJSON(from: ModelContext(container), schema: finalSchema)

    let snapshotDir = directory ?? URL(fileURLWithPath: String(describing: file))
        .deletingLastPathComponent()
        .appending(path: "__Snapshots__", directoryHint: .isDirectory)
    let snapshotURL = snapshotDir.appending(path: snapshot)

    if !FileManager.default.fileExists(atPath: snapshotURL.path) {
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try actual.write(to: snapshotURL)
        XCTFail(
            "Recorded new snapshot at \(snapshotURL.path). Re-run the test to verify.",
            file: file, line: line
        )
        return
    }

    let expected = try Data(contentsOf: snapshotURL)
    if actual != expected {
        let actualText = String(data: actual, encoding: .utf8) ?? "<binary>"
        let expectedText = String(data: expected, encoding: .utf8) ?? "<binary>"
        XCTFail(
            """
            Migration snapshot mismatch (\(snapshot)).
            --- expected
            \(expectedText.prefix(2000))
            +++ actual
            \(actualText.prefix(2000))
            """,
            file: file, line: line
        )
    }
}

// MARK: - Snapshot serialization

/// Walk every model in the schema, fetch all entities, and emit a
/// deterministic JSON document.
///
/// Determinism notes:
/// - Models are sorted by name.
/// - Entities within each model are sorted by their string-form
///   persistent identifier so re-runs produce identical bytes.
/// - The JSON encoder is configured with `.sortedKeys` and
///   `.prettyPrinted` for human-reviewable diffs.
private func snapshotJSON<S: VersionedSchema>(
    from context: ModelContext,
    schema: S.Type
) throws -> Data {
    let modelTypes = S.models.sorted { String(describing: $0) < String(describing: $1) }

    var document: [String: [SnapshotRow]] = [:]
    for type in modelTypes {
        let name = String(describing: type)
        document[name] = try fetchAndSerialize(type: type, in: context).sorted()
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(document)
}

/// Relies on Swift's implicit existential opening: callers pass a
/// `any PersistentModel.Type`, the compiler opens it to the concrete
/// type for this function's body, and `FetchDescriptor<T>` is built
/// against that concrete type.
private func fetchAndSerialize<T: PersistentModel>(
    type: T.Type,
    in context: ModelContext
) throws -> [SnapshotRow] {
    let objects = try context.fetch(FetchDescriptor<T>())
    return objects.map { obj in
        var fields: [String: String] = [:]
        for child in Mirror(reflecting: obj).children {
            guard let label = child.label, !label.hasPrefix("_") else { continue }
            fields[label] = String(describing: child.value)
        }
        return SnapshotRow(id: "\(obj.persistentModelID)", fields: fields)
    }
}

private struct SnapshotRow: Codable, Comparable {
    let id: String
    let fields: [String: String]

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.id < rhs.id }
}
