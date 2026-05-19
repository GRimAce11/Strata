import Foundation
import SwiftData

/// Bridges Strata's runtime ``MigrationPlan`` to SwiftData's compile-time
/// ``SchemaMigrationPlan`` protocol.
///
/// SwiftData requires the migration plan to be expressed as a *type* that
/// conforms to `SchemaMigrationPlan` (so it can read `static var schemas`
/// and `static var stages`). Strata builds plans as runtime values via
/// its DSL, so we need a bridge: a single static-conforming type
/// (``_StrataAppleBridgePlan``) whose `schemas` and `stages` read from a
/// thread-safe global slot (``_StrataAppleBridge``).
///
/// Use ``installed(_:_:)`` to populate the bridge for the duration of a
/// single `ModelContainer` initialisation. The bridge is cleared on
/// return so the slot is never left dangling for the next caller.
///
/// > Why is this safe? SwiftData's ``ModelContainer`` initialiser reads
/// > the static properties synchronously during init. We hold the bridge
/// > populated for that synchronous window only; concurrent containers
/// > would step on each other, so Strata serialises migrations through
/// > the bridge's own lock.
package enum SchemaMigrationPlanFactory {

    /// Build the SwiftData-native `MigrationStage` array for `plan`.
    package static func stages(for plan: MigrationPlan) -> [MigrationStage] {
        plan.stages.map { stage -> MigrationStage in
            switch stage.kind {
            case .lightweight:
                return .lightweight(
                    fromVersion: stage.fromSchema,
                    toVersion: stage.toSchema
                )

            case .custom:
                let operations = stage.operations
                let stash = MigrationStash()
                let stageLabel = stage.label

                return .custom(
                    fromVersion: stage.fromSchema,
                    toVersion: stage.toSchema,
                    willMigrate: { context in
                        StrataLog.stage.notice("willMigrate \(stageLabel, privacy: .public)")
                        for op in operations where op.phase < .assertions {
                            StrataLog.operation.debug("[will] \(op.description, privacy: .public)")
                            try op.willMigrate(context, stash: stash)
                        }
                    },
                    didMigrate: { context in
                        StrataLog.stage.notice("didMigrate \(stageLabel, privacy: .public)")
                        for op in operations where op.phase < .assertions {
                            StrataLog.operation.debug("[did]  \(op.description, privacy: .public)")
                            try op.didMigrate(context, stash: stash)
                        }
                        // Persist the body-phase writes so that
                        // assertions and downstream stages see them.
                        // We rely on FetchDescriptor (not `context.model(for:)`)
                        // throughout Strata's operations, which is why this
                        // save is now safe — fetched results remain valid
                        // across save boundaries.
                        if context.hasChanges {
                            try context.save()
                        }
                        for op in operations where op.phase >= .assertions {
                            StrataLog.operation.debug("[did]  \(op.description, privacy: .public)")
                            try op.didMigrate(context, stash: stash)
                        }
                        stash.reset()
                    }
                )
            }
        }
    }
}

// MARK: - Static bridge

/// Mutable per-process slot read by ``_StrataAppleBridgePlan``.
///
/// ## Thread-safety model
///
/// **Writes** (`setSlot` / `clearSlot`) are serialized by ``MigrationRuntime``
/// — the actor guarantees only one migration can call `setSlot` at a time.
/// Writes do not hold the lock while the `ModelContainer` init runs.
///
/// **Reads** (`currentSchemas` / `currentStages`) are called by SwiftData
/// from its own internal threads during `ModelContainer` init. They use a
/// plain `NSLock` for memory safety. No recursion is needed because `setSlot`
/// returns before SwiftData reads — the lock is never re-entered on the same
/// thread.
package final class _StrataAppleBridge: @unchecked Sendable {
    package static let shared = _StrataAppleBridge()

    private let lock = NSLock()
    private var slot: (schemas: [any VersionedSchema.Type], stages: [MigrationStage])?

    private init() {}

    /// Install schemas and stages into the slot.
    /// Called exclusively from ``MigrationRuntime/perform``.
    package func setSlot(
        schemas: [any VersionedSchema.Type],
        stages: [MigrationStage]
    ) {
        lock.lock(); defer { lock.unlock() }
        slot = (schemas, stages)
    }

    /// Clear the slot after `ModelContainer` init completes.
    /// Called from the `defer` in ``MigrationRuntime/perform``.
    package func clearSlot() {
        lock.lock(); defer { lock.unlock() }
        slot = nil
    }

    /// Read the currently-installed schemas.
    /// Returns an empty array when no migration session is active.
    package func currentSchemas() -> [any VersionedSchema.Type] {
        lock.lock(); defer { lock.unlock() }
        return slot?.schemas ?? []
    }

    /// Read the currently-installed stages.
    package func currentStages() -> [MigrationStage] {
        lock.lock(); defer { lock.unlock() }
        return slot?.stages ?? []
    }
}

/// The single SchemaMigrationPlan-conforming type Strata ships. Its two
/// static properties forward to ``_StrataAppleBridge`` so that
/// ``SafeModelContainer/make(for:plan:storeURL:safety:configurations:)``
/// can hand SwiftData what it wants without users having to declare a
/// SchemaMigrationPlan-conforming type themselves.
package enum _StrataAppleBridgePlan: SchemaMigrationPlan {
    package static var schemas: [any VersionedSchema.Type] {
        _StrataAppleBridge.shared.currentSchemas()
    }
    package static var stages: [MigrationStage] {
        _StrataAppleBridge.shared.currentStages()
    }
}
