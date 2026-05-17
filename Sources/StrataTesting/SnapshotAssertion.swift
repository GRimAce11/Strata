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
///
/// ## Stability guarantees
///
/// - `Date` values are serialized as ISO 8601 UTC strings.
/// - `UUID` values are serialized as uppercase hyphenated strings.
/// - `URL` values are serialized as absolute strings.
/// - Relationship properties (other `PersistentModel` instances) are
///   omitted — their persistent IDs change between test runs.
/// - All other scalar values use `String(describing:)`.
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
/// Determinism guarantees:
/// - Models are sorted by name.
/// - Entities are sorted by their stable persistent key (entity name + Z_PK).
/// - Date, UUID, and URL values use stable formatters.
/// - Relationship properties are omitted.
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
    let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    return objects.map { obj in
        var fields: [String: String] = [:]
        for child in Mirror(reflecting: obj).children {
            guard let label = child.label, !label.hasPrefix("_") else { continue }
            // Serialize with stable, OS-version-independent formatters.
            // stableValue returns nil for relationship properties (class instances)
            // which are omitted from the snapshot — their identifiers change
            // between test runs and cross-entity ordering is unpredictable.
            if let value = stableValue(child.value, dateFormatter: dateFormatter) {
                fields[label] = value
            }
        }
        return SnapshotRow(
            id: stablePersistentKey(obj.persistentModelID),
            fields: fields
        )
    }
}

/// Serialize `value` to a stable, OS-independent string.
/// Returns `nil` for class-type values (PersistentModel relationships).
private func stableValue(_ value: Any, dateFormatter: ISO8601DateFormatter) -> String? {
    // Stable formatters for types whose String(describing:) varies by OS/locale.
    if let date = value as? Date { return dateFormatter.string(from: date) }
    if let uuid = value as? UUID { return uuid.uuidString }
    if let url  = value as? URL  { return url.absoluteString }

    // Unwrap Optional recursively.
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let child = mirror.children.first else { return "nil" }
        return stableValue(child.value, dateFormatter: dateFormatter)
    }

    // Class-type values are PersistentModel relationships — skip them.
    if mirror.displayStyle == .class { return nil }

    return String(describing: value)
}

/// Derive a stable sort key from a `PersistentIdentifier`.
/// Uses entity name + SQLite Z_PK extracted from the identifier description,
/// giving a consistent ordering across OS versions.
private func stablePersistentKey(_ id: PersistentIdentifier) -> String {
    let desc = String(describing: id.id)
    if let slashP = desc.range(of: "/p") {
        let digits = desc[slashP.upperBound...].prefix(while: \.isNumber)
        if !digits.isEmpty { return "\(id.entityName)/\(digits)" }
    }
    return String(describing: id)
}

private struct SnapshotRow: Codable, Comparable {
    let id: String
    let fields: [String: String]

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.id < rhs.id }
}
