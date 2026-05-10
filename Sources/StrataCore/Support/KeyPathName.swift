import Foundation

/// Returns the Objective-C-style key path string for a KeyPath whose root
/// is a class (e.g. all SwiftData `@Model` types).
///
/// Used by ``Rename``, ``Backfill``, and the assertion primitives to derive
/// a human-readable property name from the KeyPath the user supplied. We do
/// not rely on private SwiftData APIs; `_kvcKeyPathString` is part of the
/// `KeyPath` runtime ABI.
///
/// - Returns: The property name (e.g. `"title"`) or `"<unknown>"` if the
///   runtime cannot resolve it (which generally means the property has
///   no `@objc` exposure — uncommon for SwiftData but possible).
public func _strataPropertyName<Root, Value>(_ keyPath: KeyPath<Root, Value>) -> String {
    keyPath._kvcKeyPathString ?? "<unknown>"
}

/// Convenience for emitting a stash key that disambiguates by source and
/// destination property pairs.
public func _strataStashKey<From, To, Value>(
    operation: String,
    fromType: From.Type,
    fromKey: KeyPath<From, Value>,
    toType: To.Type,
    toKey: AnyKeyPath
) -> String {
    "\(operation)|\(String(reflecting: fromType)).\(_strataPropertyName(fromKey))" +
    "->\(String(reflecting: toType)).\(toKey._kvcKeyPathString ?? "<unknown>")"
}
