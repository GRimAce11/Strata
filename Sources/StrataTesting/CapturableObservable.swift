public import Foundation
internal import XCTest

/// A type that can produce a value-type snapshot of its current observable
/// state, suitable for before/after assertions in migration tests.
///
/// Adopt this protocol on any `@Observable` view model whose state you
/// want to verify across a migration boundary.
///
/// ```swift
/// @Observable
/// final class PostListViewModel: CapturableObservable {
///     struct Snapshot: Sendable {
///         var postCount: Int
///         var titles: [String]
///     }
///
///     var posts: [Post] = []
///
///     func capture() -> Snapshot {
///         Snapshot(postCount: posts.count, titles: posts.map(\.title))
///     }
/// }
///
/// // In a migration test:
/// let vm = PostListViewModel(context: ModelContext(container))
/// let before = vm.capture()
/// let migratedContainer = try await migrate(store: store, to: SchemaV2.self, plan: plan)
/// vm.refresh(with: ModelContext(migratedContainer))
/// let after = vm.capture()
/// XCTAssertEqual(after.postCount, before.postCount)
/// XCTAssertEqual(after.titles, before.titles)
/// ```
public protocol CapturableObservable {
    /// A `Sendable` value type that holds a snapshot of the observable's
    /// current state. Declare this as a nested struct.
    associatedtype Snapshot: Sendable

    /// Produce a snapshot of the current state.
    func capture() -> Snapshot
}

// MARK: - Mirror-based helpers

/// Capture all non-relationship, non-backing-store properties of any object
/// as a `[String: String]` dictionary, keyed by property name.
///
/// Uses Swift's `Mirror` API. Properties with a leading underscore
/// (`_title`, `_$observationRegistrar`, etc.) and class-type values
/// (SwiftData relationships or other reference types) are excluded.
///
/// This is a lightweight alternative to declaring a full
/// ``CapturableObservable`` conformance — useful for quick assertions or
/// debugging without boilerplate.
///
/// ```swift
/// let props = captureProperties(of: viewModel)
/// XCTAssertEqual(props["postCount"], "3")
/// XCTAssertEqual(props["isLoading"], "false")
/// ```
public func captureProperties(of object: some AnyObject) -> [String: String] {
    var result: [String: String] = [:]
    for child in Mirror(reflecting: object).children {
        guard let label = child.label, !label.hasPrefix("_") else { continue }
        let m = Mirror(reflecting: child.value)
        if m.displayStyle == .class { continue }
        result[label] = String(describing: child.value)
    }
    return result
}

/// Assert that specific properties of an observable object match expected
/// string values.
///
/// Captures the object's state via `captureProperties(of:)` and checks each
/// key in `expected`. Extra properties on the object that are not in
/// `expected` are ignored.
///
/// ```swift
/// assertObservableState(of: viewModel, matches: [
///     "postCount": "3",
///     "isLoading": "false",
/// ])
/// ```
public func assertObservableState(
    of object: some AnyObject,
    matches expected: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let actual = captureProperties(of: object)
    for (key, expectedValue) in expected.sorted(by: { $0.key < $1.key }) {
        guard let actualValue = actual[key] else {
            XCTFail(
                "Property '\(key)' not found in captured state. Available: \(actual.keys.sorted().joined(separator: ", "))",
                file: file, line: line
            )
            continue
        }
        if actualValue != expectedValue {
            XCTFail(
                "Observable state mismatch for '\(key)': expected \"\(expectedValue)\", got \"\(actualValue)\"",
                file: file, line: line
            )
        }
    }
}
