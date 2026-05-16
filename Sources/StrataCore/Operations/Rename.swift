import Foundation
import SwiftData

/// Move a value from a source property to a destination property,
/// preserving entity identity across the migration.
///
/// SwiftData's default behavior for "renamed" properties (without an
/// `originalName:` hint) is to drop the source column and add a new
/// empty one — silently destroying data. ``Rename`` works around this
/// by capturing source values in the `willMigrate` phase, stashing them
/// keyed by a cross-migration row identity string, then writing them back
/// onto the destination property in `didMigrate`.
///
/// ## Identity keying
///
/// By default, row identity is derived from the entity's
/// `PersistentIdentifier` via its public `Codable` conformance (entity
/// name + SQLite primary key). This works correctly as long as the
/// `@Model` **class name** is the same in both `From` and `To`.
///
/// When your models carry a stable user-defined key (e.g. `id: String`
/// or `id: UUID` that holds the same value in both schema versions),
/// use the `sourceKey:destinationKey:` overload — it does not depend
/// on any internal representation of `PersistentIdentifier`.
///
/// ```swift
/// // Default — reliable when the @Model class name is unchanged
/// Rename(\PostV2.body, to: \PostV3.content)
///
/// // Explicit — preferred when you have a stable user-defined key
/// Rename(\PostV2.body, to: \PostV3.content,
///        sourceKey: \PostV2.id, destinationKey: \PostV3.id)
/// ```
public struct Rename<
    From: PersistentModel,
    To: PersistentModel,
    Value: Sendable
>: MigrationOperation, @unchecked Sendable {

    // @unchecked Sendable: KeyPath is not Sendable in Swift 6 but behaves
    // as an immutable singleton. All stored closures are called synchronously
    // within a single migration stage; no cross-actor sharing occurs.
    public let fromKeyPath: KeyPath<From, Value>
    public let toKeyPath: ReferenceWritableKeyPath<To, Value>
    public let description: String
    public var phase: MigrationPhase { .captures }

    /// Rows fetched per batch during `willMigrate` and `didMigrate`.
    /// Lower this to reduce peak memory on very large stores.
    public var batchSize: Int = 500

    // UUID-based stash key: collision-free, no runtime API dependency.
    // Both willMigrate and didMigrate capture the same Rename instance
    // from stage.operations, so the UUID is stable across both calls.
    private let stashKey = UUID().uuidString

    // String-keyed extractors — non-@Sendable because KeyPath<_, _> is not
    // Sendable in Swift 6. Safe: called synchronously, never across actor
    // boundaries. @unchecked Sendable on the struct covers this.
    private let sourceKeyExtractor: (From) -> String
    private let destKeyExtractor: (To) -> String

    // MARK: - Init: automatic identity (PersistentIdentifier-derived)

    public init(
        _ fromKeyPath: KeyPath<From, Value>,
        to toKeyPath: ReferenceWritableKeyPath<To, Value>
    ) {
        self.fromKeyPath = fromKeyPath
        self.toKeyPath = toKeyPath
        self.description = "Rename \(From.self).\(_strataPropertyName(fromKeyPath)) → " +
                           "\(To.self).\(_strataPropertyName(toKeyPath))"
        self.sourceKeyExtractor = { Self.persistentKey(for: $0.persistentModelID) }
        self.destKeyExtractor   = { Self.persistentKey(for: $0.persistentModelID) }
    }

    // MARK: - Init: explicit identity keys

    /// Use this overload when your models carry a stable user-defined key
    /// (e.g. `id: String` or `id: UUID`) whose value is identical in both
    /// the source and destination entities for the same logical row.
    ///
    /// - Parameters:
    ///   - fromKeyPath: The property being renamed.
    ///   - toKeyPath: The property it becomes.
    ///   - sourceKey: A keypath on `From` whose value uniquely identifies
    ///     each row and equals `destinationKey` for the same entity.
    ///   - destinationKey: A keypath on `To` that identifies the same row.
    public init<Key: Hashable & Sendable>(
        _ fromKeyPath: KeyPath<From, Value>,
        to toKeyPath: ReferenceWritableKeyPath<To, Value>,
        sourceKey: KeyPath<From, Key>,
        destinationKey: KeyPath<To, Key>
    ) {
        self.fromKeyPath = fromKeyPath
        self.toKeyPath = toKeyPath
        self.description = "Rename \(From.self).\(_strataPropertyName(fromKeyPath)) → " +
                           "\(To.self).\(_strataPropertyName(toKeyPath)) (explicit key)"
        // String-interpolate the key value: works correctly for UUID, String,
        // Int, and any other type with a meaningful String representation.
        self.sourceKeyExtractor = { "\($0[keyPath: sourceKey])" }
        self.destKeyExtractor   = { "\($0[keyPath: destinationKey])" }
    }

    // MARK: - MigrationOperation

    public func willMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        var captured: [String: Value] = [:]
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<From>()
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for object in batch {
                captured[sourceKeyExtractor(object)] = object[keyPath: fromKeyPath]
            }
            offset += batch.count
            if batch.count < batchSize { break }
        }
        stash.set(stashKey, captured)
        StrataLog.operation.info(
            "[Strata] Rename will: captured \(captured.count, privacy: .public) for \(self.description, privacy: .public)"
        )
    }

    public func didMigrate(_ context: ModelContext, stash: MigrationStash) throws {
        guard let captured: [String: Value] = stash.get(stashKey) else {
            throw MigrationError.renameStashMissing(
                model: String(describing: From.self),
                property: _strataPropertyName(fromKeyPath)
            )
        }
        guard !captured.isEmpty else { return }

        // Batch the destination fetch to avoid loading the full entity graph
        // at once. Saves between batches keep the dirty-object pool bounded.
        var restored = 0
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<To>()
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            for dest in batch {
                if let value = captured[destKeyExtractor(dest)] {
                    dest[keyPath: toKeyPath] = value
                    restored += 1
                }
            }
            if context.hasChanges { try context.save() }
            offset += batch.count
            if batch.count < batchSize { break }
        }

        StrataLog.operation.info(
            "[Strata] Rename did: restored \(restored, privacy: .public)/\(captured.count, privacy: .public) for \(self.description, privacy: .public)"
        )

        // Zero restores for a non-empty captured set means the identity mapping
        // produced no matches at all — throw rather than silently discard data.
        if restored == 0 {
            throw MigrationError.renameDataLoss(
                model: String(describing: From.self),
                property: _strataPropertyName(fromKeyPath),
                captured: captured.count,
                restored: 0
            )
        }

        // Partial restore: some rows mapped successfully but others didn't.
        // This can happen when a subset of entities has a different class name
        // (e.g. a polymorphic schema). Log a warning but do not throw, since
        // the successfully restored values are correct.
        if restored < captured.count {
            StrataLog.operation.warning(
                "[Strata] Rename partial: \(captured.count - restored, privacy: .public) of \(captured.count, privacy: .public) values had no matching destination for \(self.description, privacy: .public). Use sourceKey:destinationKey: for explicit row identity."
            )
        }
    }

    // MARK: - Row-identity key extraction (default init only)

    /// Build a stable string key for `id` using the documented `Codable`
    /// conformance of `PersistentIdentifier` (iOS 17+ / macOS 14+).
    /// The JSON includes the entity name and store-local primary key —
    /// both stable across the willMigrate/didMigrate boundary for a given row.
    private static func persistentKey(for id: PersistentIdentifier) -> String {
        // IMPORTANT: Do NOT use JSONEncoder().encode(id) or String(describing: id).
        // The outer PersistentIdentifier embeds schema-version metadata that
        // changes between willMigrate (source schema) and didMigrate (destination
        // schema), making those representations unstable as stash keys.
        //
        // id.id is the inner PersistentIdentifier.ID wrapping NSManagedObjectID.
        // Its description contains the Core Data URI:
        //   ...(x-coredata://UUID/EntityName/pN)
        // where EntityName is the unqualified class name and pN is the SQLite
        // Z_PK. Both survive the schema transition unchanged.
        let inner = String(describing: id.id)

        // Scan for /p<digits> — the Z_PK segment in the URI.
        if let slashP = inner.range(of: "/p") {
            let afterP = inner[slashP.upperBound...]
            let digits = afterP.prefix(while: \.isNumber)
            if !digits.isEmpty { return "\(id.entityName)/\(digits)" }
        }

        // Fallback: last path component with trailing punctuation stripped.
        // Handles URI formats like "p3>)" seen on some OS versions.
        let tail = inner.split(separator: "/").last.map(String.init) ?? inner
        let cleaned = tail
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces)
        return "\(id.entityName)/\(cleaned)"
    }
}
