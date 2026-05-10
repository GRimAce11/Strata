import Foundation

/// A thread-safe key-value store for passing data between a migration
/// stage's `willMigrate` (operating on the source schema) and `didMigrate`
/// (operating on the destination schema).
///
/// Operations such as ``Rename`` capture values keyed by
/// `PersistentIdentifier` in `willMigrate`, then read them back in
/// `didMigrate` to restore them onto the renamed property.
///
/// Strata owns the stash for the duration of a single stage; it is not
/// persisted across stages or across runs.
public final class MigrationStash: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: any Sendable] = [:]

    public init() {}

    /// Store a value under `key`. Overwrites any existing value.
    public func set<Value: Sendable>(_ key: String, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    /// Retrieve a previously-stored value, asserting it is of type `Value`.
    /// Returns nil if the key is unset or the stored value is a different type.
    public func get<Value: Sendable>(_ key: String, as: Value.Type = Value.self) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return storage[key] as? Value
    }

    /// Remove all stored values. Used to free memory between stages.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
