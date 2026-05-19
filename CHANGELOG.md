# Changelog

All notable changes to Strata are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **CloudKit-synced store support** — `SafeModelContainer.make` now accepts a
  `cloudKitDatabase: ModelConfiguration.CloudKitDatabase?` parameter. Pass
  `.private("iCloud.com.example.MyApp")` or `.automatic` for CloudKit stores.
  Safety is automatically capped at `.backupOnly` when CloudKit is enabled;
  rolling back a CloudKit store risks iCloud sync conflicts because schema
  changes may already have been propagated before rollback runs. The local
  backup is still retained for manual recovery.
- **`CapturableObservable` protocol** in `StrataTesting` — adopt this on any
  `@Observable` view model to produce a `Sendable` snapshot of its current
  state, enabling before/after assertions across migration boundaries.
- **`captureProperties(of:)`** — Mirror-based helper in `StrataTesting` that
  captures all non-underscore, non-relationship properties of any object as
  `[String: String]`. Useful for quick one-off checks without declaring a
  full `Snapshot` type.
- **`assertObservableState(of:matches:)`** — XCTest assertion that compares
  selected properties of an observable object against an expected dictionary,
  built on `captureProperties(of:)`.

## [0.3.0] — 2026-05-19

### Added

- **`CustomOperation` phase control** — both `init` overloads now accept
  `phase: MigrationPhase = .body`. Pass `.captures` to run before `Rename`
  stashes values, or `.assertions` to run as a post-condition check.
- **`HookContext.sourceVersion` from real store metadata** — reads
  `NSStoreModelVersionIdentifiers` from `Z_METADATA.Z_PLIST` so hook
  callbacks receive the store's actual current schema version (e.g.
  `"1.0.0"`) instead of always showing the plan's first-stage type name.
- **`SQLiteStoreBackup.readModelVersionIdentifiers(at:)`** — package-internal
  helper that parses the binary plist in `Z_METADATA.Z_PLIST` via
  `PropertyListSerialization` to extract the stored schema version identifiers.

### Fixed

- **`_StrataAppleBridge` data race** — `currentSchemas()` and
  `currentStages()` previously read `slot` without holding the lock.
  Switched from `NSLock` to `NSRecursiveLock` (required because SwiftData
  calls these properties synchronously from within the `ModelContainer` init
  that runs while the lock is already held on the same thread — a plain
  `NSLock` would deadlock).
- **Schema chain gap detection** — `MigrationPlan.validate()` now rejects
  plans where the stage chain skips a declared schema (e.g.
  `Stage(from: V1, to: V3)` when `schemas` declares `[V1, V2, V3]`).
  Previously this passed validation and V2 was silently never migrated.
- **Duplicate `ModelConfiguration` footgun** — `SafeModelContainer.make`
  now filters out any caller-supplied configuration whose URL matches
  `storeURL` before passing the list to `ModelContainer`. Passing two
  configurations for the same store caused undefined SwiftData behaviour;
  the duplicate is now discarded with a `.warning` log.
- **`SnapshotAssertion` OS-stability** — snapshot serialization now uses
  `ISO8601DateFormatter` (UTC) for `Date`, `.uuidString` for `UUID`, and
  `.absoluteString` for `URL`. Relationship properties (class-type Mirror
  children) are omitted rather than serialized as unstable object
  descriptions containing memory addresses. Row sort keys use the stable
  `entityName/Z_PK` extraction rather than `PersistentIdentifier`'s
  OS-version-dependent description.
- **Backup pruning now logged** — `BackupManager.pruneOlderThan` emits a
  `.notice` log entry (name + age in days) for each backup directory
  removed. Previously silent.
- **Orphaned `.strata-backups` parent cleaned up** — when a backup fails
  and the timestamped subdirectory is removed, `makeBackup` now also removes
  the `.strata-backups` parent if it is left empty. Prevents a stray
  directory being left after a first-launch backup failure.
- **`Rename.persistentKey` comment corrected** — the comment incorrectly
  stated that `id.id` accesses an "inner NSManagedObjectID wrapper".
  `PersistentIdentifier` conforms to `Identifiable` with `ID = Self`, so
  `id.id == id`. The comment now accurately documents why
  `String(describing: id)` is stable across migrations (it contains the Core
  Data URI with the unqualified class name and Z_PK), and why
  `JSONEncoder().encode(id)` is not (confirmed to embed schema-version
  metadata that changes across the boundary).

### Changed

- `MigrationPlan.validate()` is stricter: a stage chain that skips a
  declared intermediate schema now returns a validation error.
- `SafeModelContainer.make` silently removes duplicate configurations rather
  than forwarding them to SwiftData. A `.warning` log is emitted when a
  duplicate is detected.

## [0.2.0] — 2026-05-19

### Added

- **`StoreIntrospector` SQLite backend** — `actualSchema(at:)` now reads
  tables, columns, and indexes directly from the SQLite file using
  `sqlite3_backup_*`. `detectDrift(declared:at:)` compares the on-disk
  schema against a declared `VersionedSchema` and returns drift reasons.
  Both `strata inspect` and `strata drift` CLI commands are now fully
  functional.
- **`strata store-diff <storeA> <storeB>`** — new CLI subcommand that
  shows structural differences (added/removed/changed tables and columns)
  between two on-disk store files.
- **`Rename(_:to:sourceKey:destinationKey:)`** — explicit row-identity
  overload. Supply a user-defined keypath (e.g. `id: String` or
  `id: UUID`) for deterministic cross-migration row matching that does not
  depend on any internal `PersistentIdentifier` representation.
- **`MigrationError.renameDataLoss`** — thrown when a `Rename` captures
  values in `willMigrate` but restores zero of them in `didMigrate`.
  Previously this silently dropped data.
- **`MigrationError.postMigrationHookFailed`** — distinct error case for
  when the `postMigration` hook throws after a successful migration.
  Callers can now distinguish hook failures from migration failures.
- **`batchSize` parameter** on `Rename`, `Transform`, `Backfill`,
  `DeleteAll`, `DeleteWhere`, `Assert.noNulls`, and `Assert.unique`
  (default: 500). All operations now paginate large entity sets rather
  than loading them in one shot.
- **`sortBy` parameter on `Backfill`** — optional `[SortDescriptor<Model>]`
  for deterministic batch-pagination order on stores with non-trivial
  insert patterns.

### Fixed

- **First-launch crash** — `SafeModelContainer.make` with
  `safety: .backupAndRollback` previously called `sqlite3_open_v2` on a
  non-existent file and threw `MigrationError.backupFailed` on every new
  app install. The backup is now skipped when the store doesn't exist yet.
- **Backup on every launch** — a backup was made on every cold launch even
  when no migration was needed. Strata now reads `Z_METADATA.Z_VERSION`
  before and after `ModelContainer` init; if the version is unchanged the
  tentative backup is discarded.
- **`postMigration` hook rolling back successful migration** — if the hook
  threw (e.g. an analytics call), `catch` restored the pre-migration backup
  over an already-migrated store. The hook is now invoked outside the
  rollback-guarded scope.
- **`dryRun` temp-directory leak** — the copied store was never cleaned up
  when the dry run failed. Fixed with `defer { removeItem(tmpDir) }`.
- **Backup WAL inconsistency** — `BackupManager` and `dryRun` previously
  used `FileManager.copyItem` which could copy an inconsistent WAL state.
  Both now use `sqlite3_backup_*` (via `SQLiteStoreBackup`) which reads
  only committed transactions.
- **Backup pruning used modification date** — APFS can update the
  modification date of backup directories when any file inside changes.
  Pruning now uses `creationDateKey` which is set once and never changes.
- **`Rename.didMigrate` unbatched** — destination entities were fetched
  in one call regardless of store size. Now uses the same
  `fetchLimit`/`fetchOffset` loop as `willMigrate`.
- **`Assert.noNulls` / `Assert.unique` unbatched** — both assertions now
  paginate the entity scan. `noNulls` counts nil values incrementally;
  `unique` builds the seen-Set across batches.
- **`DeleteAll` unbatched** — now uses a no-offset batch loop: fetch →
  delete → save → repeat until empty.
- **Partial `Rename` restoration silent** — when some rows matched the
  identity key and others didn't, the unmatched values were silently
  dropped. A `.warning`-level OSLog message is now emitted for
  `restored < captured.count`.
- **`_StrataAppleBridge` stash key collision** — stash keys were derived
  via `_kvcKeyPathString` (Swift SPI) and could produce `"<unknown>"` for
  properties whose KeyPath has no ObjC representation, causing multiple
  operations to collide in the stash. Keys are now UUID-based.
- **`PostsDemo` incorrectly exposed as a public SPM product** — external
  consumers could accidentally depend on the internal example module. It
  is now a target-only dependency used exclusively by the test suite.

### Changed

- `BackupManager.makeBackup()` returns `URL?` instead of `URL`; returns
  `nil` (no backup) when the store file doesn't exist yet.
- `Rename` stash key changed from a `_kvcKeyPathString`-derived string to
  a per-instance UUID. This is an internal implementation detail with no
  API impact.
- `StoreIntrospector.Unimplemented` is preserved for source compatibility
  but is no longer thrown by any implemented method.

## [0.1.0] — 2026-05-18

Initial release. v0.1 ships Milestones 1 and 2 in full and a scaffolded
Milestone 3 (declared-schema diff is functional; on-disk SQLite
introspection has a stable protocol seam but is not yet implemented).

### Added

#### `StrataCore` — declarative migration DSL and safety layer

- `MigrationPlan` and `Stage` result-builder DSL for composing migrations.
- Operations:
  - `Rename` — preserves a property's value across a name change, using a
    PersistentIdentifier-derived stable stash key that survives the
    migration boundary.
  - `Backfill` — populates a destination property from existing data.
    Overwrites by default; opt out with `overwrite: false`.
  - `Transform` — rebuilds entities of one type into another via an
    explicit `Snapshot` bridge.
  - `DeleteAll` / `DeleteWhere` — removes rows.
  - `CustomOperation` — escape hatch for arbitrary logic.
  - `Assert.{noNulls, unique, count, custom}` — post-condition checks.
- `SafeModelContainer.make` — drop-in wrapper for `ModelContainer` that:
  - Validates the plan structurally before touching the store.
  - Copies the store and its `-wal` / `-shm` companions to a sibling
    `.strata-backups/` directory.
  - Runs configurable pre-migration and post-migration hooks.
  - Rolls back to the backup on failure with
    `safety: .backupAndRollback` (the default).
  - Prunes backups older than seven days on success.
- `SafeModelContainer.dryRun` — runs a migration against a throwaway
  copy of the store and reports the outcome without touching the
  original.
- Structured `MigrationError` with rendered descriptions for each
  failure mode.

#### `StrataTesting` — migration testing infrastructure

- `MigrationTestCase` mix-in protocol providing:
  - `fixture(schema:populate:)` — creates an isolated, populated store.
  - `migrate(store:to:plan:)` and `migrate(store:through:plan:)` —
    run migrations against fixtures.
  - `benchmarkMigration` and `seed` for performance suites.
- `assertMigrationSnapshot(fixture:through:plan:matches:)` — auto-records
  on first run, then compares deterministic JSON output on subsequent
  runs.

#### `StrataInspect` — schema diffing and on-disk introspection

- `SchemaDiff.diff(from:to:)` — structural diff between two
  `VersionedSchema` types covering models, attributes (type, nullability,
  uniqueness), and relationships. Strata never infers renames.
- `MigrationReport.render(_:)` — human-readable text rendering for diffs
  and plans.
- `StoreIntrospector` — protocol seam for on-disk SQLite introspection.
  Throws `Unimplemented` today; full backend deferred to Milestone 3.

#### `strata` CLI

- Subcommands: `inspect`, `diff`, `drift`.
- `inspect` and `drift` surface clear "scaffolded for M3" messages
  until `StoreIntrospector` lands its SQLite backend.

#### Demo & Tests

- `PostsDemo` — four schema versions and a migration plan covering
  every primitive, used as the reference for the test suite.
- Thirteen integration tests across `StrataCore`, `StrataTesting`,
  and `StrataInspect`, all hitting real SwiftData stores on disk.

#### CI

- GitHub Actions workflow with build-and-test, CLI smoke, and lint
  jobs on `macos-15`.

### Known limitations

- Non-optional new columns require a default at the property level
  because SwiftData's lightweight migration validates the destination
  schema before `didMigrate` runs.
- `Transform` requires an explicit `Snapshot` type — source and
  destination model types cannot coexist in a single `ModelContext`.
- Rename inference is intentionally not provided.
- CloudKit-synced stores are not yet supported.
- `StoreIntrospector`'s SQLite backend is not yet implemented.

[Unreleased]: https://github.com/GRimAce11/Strata/compare/0.3.0...HEAD
[0.3.0]: https://github.com/GRimAce11/Strata/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/GRimAce11/Strata/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/GRimAce11/Strata/releases/tag/0.1.0
