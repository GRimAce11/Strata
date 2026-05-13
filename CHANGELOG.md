# Changelog

All notable changes to Strata are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/GRimAce11/Strata/compare/0.1.0...HEAD
[0.1.0]: https://github.com/GRimAce11/Strata/releases/tag/0.1.0
