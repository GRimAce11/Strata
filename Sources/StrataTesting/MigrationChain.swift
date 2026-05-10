public import StrataCore
public import SwiftData
public import Foundation

public extension MigrationTestCase {

    /// Run a sequence of migrations and return a container open at the
    /// final destination schema.
    ///
    /// Used by ``assertMigrationSnapshot(from:through:plan:matches:file:line:)``
    /// to verify long migration chains. The plan should describe **every**
    /// stage between the source and the final destination — Strata does
    /// not generate intermediate plans on your behalf.
    func migrate<S: VersionedSchema>(
        store storeURL: URL,
        through finalSchema: S.Type,
        plan: MigrationPlan
    ) async throws -> ModelContainer {
        try await migrate(store: storeURL, to: finalSchema, plan: plan, safety: .none)
    }
}
