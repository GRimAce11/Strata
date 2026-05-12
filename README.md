# Strata

A declarative migration toolkit for SwiftData — safe by default, testable in CI, and introspectable when things go wrong.

> **Status:** v0.1 — Milestone 1 complete, Milestone 2 complete, Milestone 3 scaffolded.
> The declared-schema diff is functional; on-disk SQLite introspection has a stable protocol seam but is not yet implemented.

## Why

SwiftData ships with `SchemaMigrationPlan`, a sparse API that expects you to hand-write `willMigrate` and `didMigrate` closures and figure out the lifecycle constraints yourself. In practice this means:

- Renamed properties silently drop their data unless you carefully use `originalName`.
- Migrations are hard to test in isolation — you cannot easily fixture a v1 store, run the migration, and assert v2 invariants.
- There is no built-in backup or rollback if a migration fails partway.
- Schema drift between your `@Model` types and what is actually on disk is invisible.

Strata addresses these by providing a declarative DSL for migrations, a `SafeModelContainer` wrapper that backs up the store and rolls back on failure, a test harness with snapshot assertions, and a schema-diff tool.

## Install

```swift
// Package.swift
.package(url: "https://github.com/GRimAce11/Strata.git", from: "0.1.0"),

// Target dependencies
.product(name: "StrataCore",    package: "Strata"),  // production code
.product(name: "StrataTesting", package: "Strata"),  // test target only
.product(name: "StrataInspect", package: "Strata"),  // tooling / diagnostics
```

Strata requires iOS 17 / macOS 14 / Swift 6.

## Quickstart — the Posts example

The package ships a real migration chain (`Examples/PostsDemo`) exercising every primitive. The short version:

```swift
import StrataCore
import SwiftData

let plan = MigrationPlan(schemas: [
    PostsSchemaV1.self, PostsSchemaV2.self, PostsSchemaV3.self, PostsSchemaV4.self,
]) {
    // Lightweight migration — SwiftData handles it, no user code runs.
    Stage(from: PostsSchemaV1.self, to: PostsSchemaV2.self)

    // Custom migration with a rename.
    Stage(from: PostsSchemaV2.self, to: PostsSchemaV3.self) {
        Rename(\PostsSchemaV2.Post.body, to: \PostsSchemaV3.Post.content)

        CustomOperation("Attach default author") { context in
            for post in try context.fetch(FetchDescriptor<PostsSchemaV3.Post>()) where post.author == nil {
                let a = PostsSchemaV3.Author(id: UUID().uuidString, name: "Unknown")
                context.insert(a)
                post.author = a
            }
        }
    }

    // Backfill new non-optional fields, then assert uniqueness.
    Stage(from: PostsSchemaV3.self, to: PostsSchemaV4.self) {
        Backfill(\PostsSchemaV4.Post.publishedAt) { $0.createdAt }
        Backfill(\PostsSchemaV4.Post.slug)        { PostsSlug.slugify($0.title) + "-" + $0.id.prefix(6) }
        Assert.unique(\PostsSchemaV4.Post.slug)
    }
}

let container = try await SafeModelContainer.make(
    for: Schema(versionedSchema: PostsSchemaV4.self),
    plan: plan,
    storeURL: URL.applicationSupportDirectory.appending(path: "posts.store"),
    safety: .backupAndRollback
)
```

## Operations

| Operation | Purpose |
|---|---|
| `Stage(from:to:)` (no body) | Lightweight migration — SwiftData's default heuristics |
| `Rename(\From.x, to: \To.y)` | Move a value across a property-name change |
| `Backfill(\.x) { ... }` | Populate a new property from existing data |
| `Transform(from:to:capture:build:)` | Rebuild entities of one type into another |
| `DeleteAll(M.self)` | Remove every row of a model |
| `DeleteWhere(M.self) { ... }` | Remove rows matching a predicate |
| `CustomOperation("...") { ... }` | Escape hatch for arbitrary logic |
| `Assert.noNulls(\.x)` | Post-condition: no nil values |
| `Assert.unique(\.x)` | Post-condition: distinct values |
| `Assert.count(of:satisfies:)` | Post-condition: count matches predicate |
| `Assert.custom("name") { ... }` | Free-form boolean post-condition |

Operations are sorted internally by phase before execution: captures (`Rename`'s `willMigrate` side) run first, then the body, then assertions — so you can list them in whatever order reads best.

## Testing migrations

`StrataTesting` plugs in to XCTest with a mix-in protocol:

```swift
final class PostsMigrationTests: XCTestCase, MigrationTestCase {
    func test_V2_to_V3_rename_preserves_body() async throws {
        let v2Store = try fixture(schema: PostsSchemaV2.self) { ctx in
            ctx.insert(PostsSchemaV2.Post(id: "p1", title: "T", body: "preserve me",
                                          createdAt: .now, authorName: nil))
        }
        let container = try await migrate(store: v2Store, to: PostsSchemaV3.self, plan: PostsMigrationPlan.plan)
        let posts = try ModelContext(container).fetch(FetchDescriptor<PostsSchemaV3.Post>())
        XCTAssertEqual(posts.first?.content, "preserve me")
    }
}
```

Snapshot assertions are also available:

```swift
try await assertMigrationSnapshot(
    fixture: v1Store, through: PostsSchemaV4.self,
    plan: PostsMigrationPlan.plan,
    matches: "v1_to_v4.json"
)
```

On the first run the snapshot is recorded; subsequent runs compare against the recorded bytes.

## Schema diffing

`StrataInspect` provides a structural diff between two `VersionedSchema` types:

```swift
import StrataInspect

let diff = SchemaDiff.diff(from: PostsSchemaV2.self, to: PostsSchemaV3.self)
print(MigrationReport.render(diff))
// → Schema diff: PostsSchemaV2 → PostsSchemaV3
//   ──────────────────────────────────────────────────
//     + model Author
//     + Post.content: String
//     - Post.body
//     + Post.author (relationship)
//     - Post.authorName
```

Strata does **not** infer renames — they always appear as a remove + add. That is a design choice: heuristic rename inference produces false positives (renaming `name → displayName` looks identical to deleting `name` and adding `displayName`), and a destructive false positive is much worse than a slightly noisier diff.

## How safety works

`SafeModelContainer.make(...)` with `safety: .backupAndRollback` (the default):

1. Validates the plan structurally (every stage's schemas declared; stages adjacent).
2. Copies the store (and `-wal`/`-shm` companions) into a sibling `.strata-backups/backup-<timestamp>/` directory.
3. Runs your pre-migration hook, if any.
4. Hands the plan to SwiftData via a static bridge type that conforms to `SchemaMigrationPlan`.
5. Runs your post-migration hook, if any.
6. On success: prunes backup directories older than seven days. On failure: restores the store from the backup and throws `MigrationError.migrationFailed(underlying:backupAvailableAt:)`.

The static bridge (`_StrataAppleBridge`) holds the lock for the entire `ModelContainer` initialization, so concurrent calls serialise rather than corrupting each other's slot.

## Architecture

```
StrataCore        — DSL types, operations, SafeModelContainer, backup/rollback
StrataTesting     — MigrationTestCase, fixture/migrate helpers, snapshot assertions
StrataInspect     — SchemaDiff, MigrationReport, StoreIntrospector (scaffolded)
StrataCLI         — `strata` binary; inspect / diff / drift subcommands
```

Module boundaries are strict: `StrataCore` has no internal dependency on `StrataTesting` or `StrataInspect`, so they can be vended separately.

### The `Rename` mechanism

A common Strata gotcha: SwiftData's lightweight migration drops a "renamed" property unless you add an `originalName:` hint. Strata's `Rename` works around this by:

1. **willMigrate** — fetches every entity of the source type and captures the source property's value into a stash, keyed by a stable string derived from the model's `PersistentIdentifier` (the entity name + the URI tail of the underlying `NSManagedObjectID`).
2. **didMigrate** — fetches every entity of the destination type, computes the same stable key, looks the value up in the stash, and writes it onto the destination property.

We do not use `PersistentIdentifier` directly as the dictionary key because the identifier value carries schema-version metadata that gets reissued across the migration boundary — equal underlying ObjectIDs do not always produce equal identifiers.

## Known limitations

1. **Non-optional new columns need defaults.** SwiftData's migration validates the destination schema *before* `didMigrate` runs. A new non-optional property without a default value will fail validation regardless of any `Backfill` you have written. Declare the new column with a default (`var publishedAt: Date = .distantPast`), then have `Backfill` overwrite it with the real value.
2. **`Transform`** requires an explicit `Snapshot` type because source and destination model types cannot coexist in a single `ModelContext`.
3. **Rename inference** is not provided — explicit only.
4. **CloudKit-synced stores** have their own migration semantics; Strata does not yet handle them.
5. **`StoreIntrospector`** has a stable protocol seam but no sqlite backend yet.

## Milestone status

| Milestone | Status |
|---|---|
| 1 — Core DSL + safety layer | ✅ Complete |
| 2 — Migration testing infrastructure | ✅ Complete |
| 3 — Schema diff + sqlite introspection + CLI | 🟡 Declared-schema diff complete; on-disk introspection scaffolded only |

## Contributing

This is a from-scratch v0.1 — pre-tagging it now would be premature. PRs welcome once we stabilise the public surface and ship an `0.1.0` tag.

## Author / License

Chethan Nayak <chethannayak010@gmail.com>
MIT — see [LICENSE](LICENSE).
