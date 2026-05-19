import Foundation
import SwiftData

/// Serializes all migration sessions across the process.
///
/// `_StrataAppleBridge` requires a process-global static slot — SwiftData's
/// `SchemaMigrationPlan` protocol reads `static var schemas/stages`, so there
/// is no clean per-call injection path. `MigrationRuntime` wraps this
/// unavoidable global with actor-based serialization: only one migration can
/// hold the slot at any time, so concurrent migrations on different stores
/// queue up rather than racing to overwrite each other's stages.
///
/// ## Concurrency model
///
/// ```
/// Task A: await perform(...)  ─┐
///                              │  actor processes A exclusively
/// Task B: await perform(...)   │  B is suspended in the actor's mailbox
///                              │  until A's perform() returns
///                             ─┘
/// Task B: resumes, runs perform(...)
/// ```
///
/// Because `perform` has no `await` inside (ModelContainer.init is
/// synchronous), the actor never yields mid-migration. Task B cannot
/// interleave with Task A's bridge slot.
///
/// ## What this does not guarantee
///
/// If the process crashes while `perform` is running, the bridge slot is
/// lost with the process. On next launch a fresh `MigrationRuntime` starts
/// clean. Crash detection and recovery are handled separately by
/// ``MigrationJournal`` and ``MigrationRecoveryCoordinator``.
actor MigrationRuntime {
    package static let shared = MigrationRuntime()
    private init() {}

    /// Execute `work` as the sole active migration in this process.
    ///
    /// Callers are queued by the actor — if another migration is in flight,
    /// this call suspends until that migration returns. Inside `work`, the
    /// static bridge slot is populated so SwiftData reads the correct stages
    /// during `ModelContainer` initialisation.
    ///
    /// - Parameters:
    ///   - schemas: The schema chain for this migration plan.
    ///   - stages:  The SwiftData-native stages to install into the bridge.
    ///   - work:    A ``_MigrationWorkBox`` carrying the `ModelContainer`
    ///              creation closure. Using a box (instead of a raw closure)
    ///              lets us cross the actor boundary without requiring
    ///              `Schema` and `ModelConfiguration` to conform to `Sendable`.
    /// - Returns: Whatever `work` returns (typically a `ModelContainer`).
    /// - Throws:  Rethrows any error from `work` after clearing the slot.
    func perform<T: Sendable>(
        schemas: [any VersionedSchema.Type],
        stages: [MigrationStage],
        _ work: _MigrationWorkBox<T>
    ) throws -> T {
        _StrataAppleBridge.shared.setSlot(schemas: schemas, stages: stages)
        defer { _StrataAppleBridge.shared.clearSlot() }
        return try work.execute()
    }
}

/// A `@unchecked Sendable` wrapper that carries a synchronous throwing
/// closure across the actor boundary into ``MigrationRuntime/perform``.
///
/// **Why `@unchecked Sendable` is sound here:**
///
/// 1. The closure is called synchronously inside `MigrationRuntime.perform`.
/// 2. The actor guarantees only one `perform` executes at a time — no
///    concurrent access to the captured values occurs.
/// 3. The closure lifetime is strictly bounded to the single `perform` call.
/// 4. Captured types (`Schema`, `ModelConfiguration`, etc.) are created and
///    consumed on the same Swift cooperative-threading executor hop.
package struct _MigrationWorkBox<T: Sendable>: @unchecked Sendable {
    private let closure: () throws -> T

    package init(_ closure: @escaping () throws -> T) {
        self.closure = closure
    }

    package func execute() throws -> T {
        try closure()
    }
}
