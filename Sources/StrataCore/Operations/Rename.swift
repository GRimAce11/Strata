import Foundation
import SwiftData

/// Move a value from a source property to a destination property,
/// preserving entity identity across the migration.
///
/// SwiftData's default behavior for "renamed" properties (without an
/// `originalName:` hint) is to drop the source column and add a new
/// empty one — silently destroying data. ``Rename`` works around this
/// by capturing source values in the `willMigrate` phase, stashing them
/// keyed by `PersistentIdentifier`, then writing them back onto the
/// destination property in `didMigrate`.
///
/// The `Value` types of both KeyPaths must match. If you need a type
/// change as well as a rename, use ``Transform`` or ``Backfill``
/// instead — the compiler will steer you there.
///
/// ```swift
/// Rename(\PostV1.title, to: \PostV2.name)
/// ```
public struct Rename<
    From: PersistentModel,
    To: PersistentModel,
    Value: Sendable
>: MigrationOperation, @unchecked Sendable {

    // KeyPaths are not Sendable in Swift 6 but immutable Swift KeyPath
    // instances are effectively constants; the struct is Sendable in
    // practice because every stored property is read-only and value-typed
    // (or, in the case of KeyPath, a singleton-like immutable reference).
    public let fromKeyPath: KeyPath<From, Value>
    public let toKeyPath: ReferenceWritableKeyPath<To, Value>
    public let description: String
    public var phase: MigrationPhase { .captures }

    private let stashKey: String

    public init(
        _ fromKeyPath: KeyPath<From, Value>,
        to toKeyPath: ReferenceWritableKeyPath<To, Value>
    ) {
        self.fromKeyPath = fromKeyPath
        self.toKeyPath = toKeyPath
        let fromName = _strataPropertyName(fromKeyPath)
        let toName = _strataPropertyName(toKeyPath)
        self.description = "Rename \(From.self).\(fromName) → \(To.self).\(toName)"
        self.stashKey = _strataStashKey(
            operation: "Rename",
            fromType: From.self,
            fromKey: fromKeyPath,
            toType: To.self,
            toKey: toKeyPath
        )
    }

    public func willMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        let descriptor = FetchDescriptor<From>()
        let objects = try context.fetch(descriptor)
        // We key the stash by a stable string derived from the model's
        // PersistentIdentifier (entityName + a hash of its opaque id).
        // PersistentIdentifier values themselves do not always compare
        // equal across the migration boundary — SwiftData wraps the
        // underlying NSManagedObjectID with schema-specific metadata,
        // so we extract just the pieces that survive.
        var captured: [String: Value] = [:]
        captured.reserveCapacity(objects.count)
        for object in objects {
            captured[Self.stableKey(for: object.persistentModelID)] = object[keyPath: fromKeyPath]
        }
        stash.set(stashKey, captured)
        StrataLog.operation.info(
            "[Strata] Rename will: captured \(captured.count, privacy: .public) of \(objects.count, privacy: .public) for \(self.description, privacy: .public)"
        )
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        guard let captured: [String: Value] = stash.get(stashKey) else {
            throw MigrationError.renameStashMissing(
                model: String(describing: From.self),
                property: _strataPropertyName(fromKeyPath)
            )
        }
        let destinations = try context.fetch(FetchDescriptor<To>())
        var restored = 0
        for dest in destinations {
            let key = Self.stableKey(for: dest.persistentModelID)
            if let value = captured[key] {
                dest[keyPath: toKeyPath] = value
                restored += 1
            }
        }
        StrataLog.operation.info(
            "[Strata] Rename did: restored \(restored, privacy: .public)/\(captured.count, privacy: .public) for \(self.description, privacy: .public)"
        )
    }

    /// Extract a key that is stable across the migration boundary.
    ///
    /// SwiftData's `PersistentIdentifier` does not always compare equal
    /// across a schema migration — internally it carries schema-version
    /// metadata that gets reissued. The pieces that *do* survive are the
    /// underlying NSManagedObjectID URI (entityName + primary key) and the
    /// store identifier. We Base64-encode the JSON form of the identifier
    /// because the public API exposes Codable conformance but no direct
    /// URI accessor; the JSON includes the parts that survive.
    private static func stableKey(for id: PersistentIdentifier) -> String {
        // entityName + the URI tail extracted from the description.
        // `String(describing: id.id)` yields a form that contains the URI
        // in angle brackets; we extract everything after the last "/".
        let description = String(describing: id.id)
        let tail = description.split(separator: "/").last.map(String.init) ?? description
        // Strip any trailing ">)" punctuation.
        let cleaned = tail.replacingOccurrences(of: ">", with: "")
                          .replacingOccurrences(of: ")", with: "")
                          .trimmingCharacters(in: .whitespaces)
        return "\(id.entityName)/\(cleaned)"
    }
}
