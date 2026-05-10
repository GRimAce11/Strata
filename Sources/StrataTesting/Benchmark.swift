public import Foundation
public import StrataCore
public import SwiftData

public extension MigrationTestCase {

    /// Time a migration end-to-end. Returns the duration plus the
    /// migrated container so the caller can run further assertions.
    ///
    /// Intended for benchmark suites (`swift test --filter Benchmark`),
    /// not for correctness assertions — `Duration` values are subject
    /// to scheduler noise on busy machines.
    func benchmarkMigration<S: VersionedSchema>(
        store storeURL: URL,
        to finalSchema: S.Type,
        plan: MigrationPlan
    ) async throws -> (duration: Duration, container: ModelContainer) {
        let clock = ContinuousClock()
        let start = clock.now
        let container = try await SafeModelContainer.make(
            for: Schema(versionedSchema: finalSchema),
            plan: plan,
            storeURL: storeURL,
            safety: .none
        )
        return (clock.now - start, container)
    }

    /// Seed a store with N entities produced by the provided builder.
    /// Useful for measuring how a migration scales with row count.
    func seed<S: VersionedSchema, M: PersistentModel>(
        schema: S.Type,
        count: Int,
        each: (Int, ModelContext) throws -> M
    ) throws -> URL {
        try fixture(schema: schema) { context in
            for i in 0..<count {
                let model = try each(i, context)
                context.insert(model)
            }
        }
    }
}
