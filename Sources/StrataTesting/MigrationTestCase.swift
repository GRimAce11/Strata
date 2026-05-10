public import StrataCore
public import SwiftData
public import Foundation

/// Marker protocol whose default extensions provide the fixture and
/// migrate helpers used by Strata-aware tests.
///
/// Strata's testing helpers are intentionally framework-agnostic — they
/// do not require `XCTestCase`. You can mix this protocol into an
/// `XCTestCase` subclass, into a `@Suite`-decorated Swift Testing type,
/// or into a plain class used by a custom runner.
///
/// Conformance is empty by design. The protocol exists so that callers
/// can write `extension MigrationTestCase` themselves to add
/// project-specific helpers.
public protocol MigrationTestCase: AnyObject {}

public extension MigrationTestCase {

    /// Create a fresh, isolated SwiftData store at the given version,
    /// populate it via the supplied closure, and return the file URL.
    ///
    /// The store lives in the system temporary directory under a unique
    /// path; nothing else uses it. Strata returns the URL rather than a
    /// container so the caller can immediately re-open it through the
    /// migration pipeline being tested.
    ///
    /// - Parameters:
    ///   - schema: The `VersionedSchema` to materialise.
    ///   - populate: A closure that receives a `ModelContext` bound to
    ///     the fresh store. Insert your fixture entities here.
    /// - Returns: The store URL.
    func fixture<S: VersionedSchema>(
        schema: S.Type,
        populate: (ModelContext) throws -> Void
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "strata-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appending(path: "fixture.store")

        let container = try ModelContainer(
            for: Schema(versionedSchema: schema),
            configurations: ModelConfiguration(schema: Schema(versionedSchema: schema), url: url)
        )
        let context = ModelContext(container)
        try populate(context)
        try context.save()
        return url
    }

    /// Open the store at `storeURL` against the destination schema and
    /// run the migration plan.
    ///
    /// Unlike production code which would use ``SafeModelContainer/make``,
    /// this helper opts out of backup/rollback by default — tests
    /// usually want to observe failures, not silently restore.
    func migrate<S: VersionedSchema>(
        store storeURL: URL,
        to destinationSchema: S.Type,
        plan: MigrationPlan,
        safety: SafeModelContainer.Safety = .none
    ) async throws -> ModelContainer {
        try await SafeModelContainer.make(
            for: Schema(versionedSchema: destinationSchema),
            plan: plan,
            storeURL: storeURL,
            safety: safety
        )
    }
}
