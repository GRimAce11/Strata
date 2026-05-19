<h1 align="center">Strata</h1>

<p align="center">
  <strong>Safe, testable, introspectable SwiftData migrations.</strong><br/>
  Declarative DSL, automatic backup &amp; rollback, fixture-based migration tests,<br/>
  and schema diffing — everything SwiftData's <code>SchemaMigrationPlan</code> doesn't give you.
</p>

<p align="center">
  <a href="https://github.com/GRimAce11/Strata/actions/workflows/ci.yml"><img src="https://github.com/GRimAce11/Strata/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-6.0%2B-orange?logo=swift&logoColor=white" alt="Swift 6.0+">
  <img src="https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20watchOS%2010%20%7C%20tvOS%2017%20%7C%20visionOS%201-blue" alt="Platforms">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License: MIT">
  <a href="https://swiftpackageindex.com/GRimAce11/Strata"><img src="https://img.shields.io/badge/Swift%20Package%20Index-Strata-informational" alt="Swift Package Index"></a>
</p>

---

## What is Strata?

Strata is an open-source, MIT-licensed migration toolkit for SwiftData. It replaces the ceremony of hand-writing `willMigrate`/`didMigrate` closures with a declarative DSL, adds automatic store backup and rollback so a failing migration never corrupts user data, and ships a test harness that lets you fixture a v1 store, migrate it, and assert v2 invariants — all in a regular `XCTestCase`.

```swift
let plan = MigrationPlan(schemas: [SchemaV1.self, SchemaV2.self, SchemaV3.self]) {
    Stage(from: SchemaV1.self, to: SchemaV2.self)   // lightweight — SwiftData handles it

    Stage(from: SchemaV2.self, to: SchemaV3.self) {
        Rename(\PostV2.body, to: \PostV3.content)
        Backfill(\PostV3.slug) { post in slugify(post.title) + "-" + post.id.prefix(6) }
        Assert.unique(\PostV3.slug)
    }
}

let container = try await SafeModelContainer.make(
    for: Schema(versionedSchema: SchemaV3.self),
    plan: plan,
    storeURL: .applicationSupportDirectory.appending(path: "app.store"),
    safety: .backupAndRollback
)
```

## Why Strata?

| | Strata | Raw `SchemaMigrationPlan` |
|---|:-:|:-:|
| Declarative DSL | ✅ | ❌ |
| Rename without data loss | ✅ | ❌ (silent drop) |
| Automatic store backup | ✅ | ❌ |
| Rollback on failure | ✅ | ❌ |
| Post-condition assertions | ✅ | ❌ |
| Fixture-based migration tests | ✅ | ❌ |
| Snapshot diff assertions | ✅ | ❌ |
| Declared-schema diff | ✅ | ❌ |
| Structured error reporting | ✅ | ❌ |
| Swift 6 strict concurrency | ✅ | ✅ |
| Zero third-party dependencies (core) | ✅ | ✅ |

## Requirements

| Swift | iOS | macOS | Mac Catalyst | tvOS | watchOS | visionOS |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 6.0+ | 17+ | 14+ | 17+ | 17+ | 10+ | 1.0+ |

## Installation

### Swift Package Manager

Add Strata to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/GRimAce11/Strata", from: "0.3.0"),
],
targets: [
    .target(name: "MyApp",      dependencies: ["StrataCore"]),
    .testTarget(name: "MyTests", dependencies: ["StrataCore", "StrataTesting"]),
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste
`https://github.com/GRimAce11/Strata`.

**Products**

| Product | Link against | Use for |
|---|---|---|
| `StrataCore` | App target | Migration plans, `SafeModelContainer`, operations |
| `StrataTesting` | Test target only | `MigrationTestCase`, fixture helpers, snapshot assertions |
| `StrataInspect` | App / tool target | `SchemaDiff`, `MigrationReport`, CLI integration |

## Quick start — Posts app, v1 → v4

The package ships a complete reference migration (`Examples/PostsDemo`) that
covers every primitive. Here is the abbreviated walkthrough.

### 1. Declare your schema versions

```swift
// v1 — initial release
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [Post.self]

    @Model final class Post {
        @Attribute(.unique) var id: String
        var title: String
        var body: String          // will be renamed to `content` in v3
        var createdAt: Date
    }
}

// v2 — add optional authorName (lightweight, no custom code needed)
// v3 — rename body → content, introduce Author relationship
// v4 — add non-optional publishedAt: Date and slug: String
```

### 2. Write the migration plan

```swift
import StrataCore

enum PostsMigrationPlan {
    static let plan = MigrationPlan(schemas: [
        SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self,
    ]) {
        // Lightweight — SwiftData adds the optional column, nothing else needed.
        Stage(from: SchemaV1.self, to: SchemaV2.self)

        // Custom — preserve body value across the rename, attach authors.
        Stage(from: SchemaV2.self, to: SchemaV3.self) {
            Rename(\PostV2.body, to: \PostV3.content)

            CustomOperation("Attach default Author to every post") { context in
                for post in try context.fetch(FetchDescriptor<PostV3>()) where post.author == nil {
                    let author = Author(id: UUID().uuidString, name: "Unknown")
                    context.insert(author)
                    post.author = author
                }
            }
        }

        // Custom — backfill new non-optional fields, assert uniqueness.
        Stage(from: SchemaV3.self, to: SchemaV4.self) {
            Backfill(\PostV4.publishedAt) { $0.createdAt }
            Backfill(\PostV4.slug)        { slugify($0.title) + "-" + $0.id.prefix(6) }
            Assert.unique(\PostV4.slug)
        }
    }
}
```

### 3. Replace your `ModelContainer` initialiser

```swift
// Before
let container = try ModelContainer(for: ..., migrationPlan: ...)

// After — automatic backup, rollback on failure, pre/post hooks
let container = try await SafeModelContainer.make(
    for: Schema(versionedSchema: SchemaV4.self),
    plan: PostsMigrationPlan.plan,
    storeURL: URL.applicationSupportDirectory.appending(path: "posts.store"),
    safety: .backupAndRollback   // .none / .backupOnly also available
)
```

On failure Strata restores the store from the backup and throws
`MigrationError.migrationFailed(underlying:backupAvailableAt:)` — the app
starts again from a known-good state.

## Operations

| Operation | Phase | Purpose |
|---|---|---|
| `Stage(from:to:)` | — | Lightweight migration; no body |
| `Rename(\From.x, to: \To.y)` | Capture + Body | Preserve a value across a property-name change |
| `Backfill(\.x) { ... }` | Body | Populate a new property from existing data |
| `Transform(from:to:capture:build:)` | Capture + Body | Rebuild entities of one type into another |
| `DeleteAll(M.self)` | Body | Remove every row of a model |
| `DeleteWhere(M.self) { ... }` | Body | Remove rows matching a predicate |
| `CustomOperation("...") { ... }` | Body | Escape hatch for arbitrary `ModelContext` work |
| `Assert.noNulls(\.x)` | Assertion | Post-condition: no nil values |
| `Assert.unique(\.x)` | Assertion | Post-condition: all values distinct |
| `Assert.count(of:satisfies:)` | Assertion | Post-condition: row count matches predicate |
| `Assert.custom("...") { ... }` | Assertion | Free-form boolean post-condition |

Operations execute in phase order — captures first, then body, then assertions —
regardless of the order you list them in the stage body. This means `Rename`
always captures before any `Backfill` runs, and assertions always see the fully
written state.

### `Rename` — safe renames without `originalName:`

SwiftData's default behavior for renamed properties is to silently drop the
source column and add a new empty one. `Rename` works around this:

1. **willMigrate** — fetches all source entities, stashes each value keyed by a
   stable string derived from the row's URI (`entityName/primaryKey`).
2. **didMigrate** — fetches all destination entities, looks each up in the stash,
   and writes the preserved value onto the new property.

```swift
Rename(\PostV2.body, to: \PostV3.content)
// "Renamed payload" in PostV2.body is now in PostV3.content — not lost.
```

### `Backfill` — fill new properties

```swift
// Non-optional Date — requires a default at the property level in the schema
// (see "Known limitations"), then Backfill overwrites it.
Backfill(\PostV4.publishedAt) { post in post.createdAt }

// Computed slug
Backfill(\PostV4.slug) { post in slugify(post.title) + "-" + post.id.prefix(6) }

// Only fill rows that don't already have a value
Backfill(\PostV4.tagline, overwrite: false) { _ in "Draft" }
```

### `Transform` — rebuild across types

Use when neither `Rename` nor `Backfill` is enough, e.g. denormalising one
entity into two, or inverting a relationship. Provide an explicit `Snapshot`
type to bridge the two migration phases:

```swift
struct PostSnapshot: Sendable {
    let title: String
    let authorName: String?
    let createdAt: Date
}

Transform(
    from: PostV2.self,
    to: PostV3.self,
    capture: { old in PostSnapshot(title: old.title, authorName: old.authorName, createdAt: old.date) },
    build: { context, snap in
        let author = Author(id: UUID().uuidString, name: snap.authorName ?? "Unknown")
        context.insert(author)
        let post = PostV3(title: snap.title, content: "", createdAt: snap.createdAt, author: author)
        context.insert(post)
    }
)
```

### `Assert` — post-condition checks

Assertions run after all body operations. If one throws, the migration fails and
(with `safety: .backupAndRollback`) the store is restored.

```swift
Assert.noNulls(\PostV4.slug)               // zero nil slugs
Assert.unique(\PostV4.slug)                // no duplicate slugs
Assert.count(of: PostV4.self) { $0 > 0 }  // at least one post survived
Assert.custom("authors linked") { ctx in
    try ctx.fetch(FetchDescriptor<PostV4>()).allSatisfy { $0.author != nil }
}
```

### Pre / post hooks

Run arbitrary code before migration begins or after it succeeds:

```swift
MigrationPlan(
    schemas: [...],
    preMigration:  { ctx in analytics.track("migration_started", version: ctx.sourceVersion) },
    postMigration: { ctx in analytics.track("migration_done",    version: ctx.destinationVersion) }
) { ... }
```

## Safety layer

`SafeModelContainer.make` lifecycle with `safety: .backupAndRollback`:

1. **Validate** the plan structurally (schemas listed, stages adjacent).
2. **Back up** the `.store` file and its `-wal`/`-shm` companions to
   `.strata-backups/backup-<timestamp>/` next to the store.
3. Run `preMigration` hook.
4. **Migrate** via SwiftData (operations execute inside `didMigrate`).
5. Run `postMigration` hook.
6. **Prune** backups older than 7 days.
7. On any error: **restore** from backup, throw
   `MigrationError.migrationFailed(underlying:backupAvailableAt:)`.

### Dry run

Test whether a migration will succeed against the current user's real store
without touching it:

```swift
let result = await SafeModelContainer.dryRun(
    for: Schema(versionedSchema: SchemaV4.self),
    plan: MyMigrationPlan.plan,
    storeURL: liveStoreURL
)
switch result {
case .success:         print("safe to migrate")
case .failure(let e): print("would fail: \(e)")
}
```

## Testing migrations

`StrataTesting` plugs into `XCTestCase` via a mix-in protocol — no subclass required:

```swift
import XCTest
import StrataCore
import StrataTesting

final class PostsMigrationTests: XCTestCase, MigrationTestCase {

    func test_rename_preserves_body_as_content() async throws {
        // 1. Build an isolated source store with real data
        let store = try fixture(schema: SchemaV2.self) { ctx in
            ctx.insert(PostV2(id: "p1", title: "Hello", body: "Rename me", createdAt: .now))
        }

        // 2. Run the migration
        let container = try await migrate(store: store, to: SchemaV3.self, plan: MyPlan.plan)

        // 3. Assert
        let posts = try ModelContext(container).fetch(FetchDescriptor<PostV3>())
        XCTAssertEqual(posts.first?.content, "Rename me")
    }

    func test_backfill_sets_publishedAt_from_createdAt() async throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try fixture(schema: SchemaV3.self) { ctx in
            ctx.insert(PostV3(id: "p1", title: "T", content: "C", createdAt: created))
        }

        let container = try await migrate(store: store, to: SchemaV4.self, plan: MyPlan.plan)
        let post = try ModelContext(container).fetch(FetchDescriptor<PostV4>()).first!
        XCTAssertEqual(post.publishedAt, created)
    }

    func test_full_chain_V1_to_V4() async throws {
        let store = try fixture(schema: SchemaV1.self) { ctx in
            ctx.insert(PostV1(id: "p1", title: "Sample", body: "Body", createdAt: .now))
        }
        let container = try await migrate(store: store, through: SchemaV4.self, plan: MyPlan.plan)
        let posts = try ModelContext(container).fetch(FetchDescriptor<PostV4>())
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.content, "Body")
        XCTAssertFalse(posts.first?.slug.isEmpty ?? true)
    }
}
```

### Snapshot assertions

On the first run the current store state is recorded to a JSON file; subsequent
runs compare against the recorded bytes:

```swift
try await assertMigrationSnapshot(
    fixture: v1Store,
    through: SchemaV4.self,
    plan: MyPlan.plan,
    matches: "v1_to_v4.json"      // written to __Snapshots__/ next to this file
)
```

The JSON is sorted and pretty-printed so diffs are reviewable in code review.

### Observable view model assertions

`CapturableObservable` lets you snapshot an `@Observable` view model before and after a migration and assert on its state.

```swift
@Observable
final class PostListViewModel: CapturableObservable {
    struct Snapshot: Sendable {
        var postCount: Int
        var titles: [String]
    }

    var posts: [Post] = []

    func capture() -> Snapshot {
        Snapshot(postCount: posts.count, titles: posts.map(\.title))
    }
}

// In a migration test:
let before = viewModel.capture()
let migratedContainer = try await migrate(store: store, to: SchemaV4.self, plan: plan)
viewModel.reload(context: ModelContext(migratedContainer))
let after = viewModel.capture()
XCTAssertEqual(after.postCount, before.postCount)
```

For quick one-off checks without a `Snapshot` type, use the Mirror-based helper:

```swift
// Captures all non-underscore, non-relationship properties as [String: String]
assertObservableState(of: viewModel, matches: [
    "postCount": "3",
    "isLoading": "false",
])
```

### Performance

```swift
func test_migrate_10k_posts_in_under_two_seconds() async throws {
    let store = try seed(schema: SchemaV3.self, count: 10_000) { i, ctx in
        PostV3(id: "p\(i)", title: "Post \(i)", content: "Body", createdAt: .now)
    }
    let (duration, _) = try await benchmarkMigration(store: store, to: SchemaV4.self, plan: MyPlan.plan)
    XCTAssertLessThan(duration, .seconds(2))
}
```

## Schema diffing

`StrataInspect` compares two `VersionedSchema` types structurally:

```swift
import StrataInspect

let diff = SchemaDiff.diff(from: SchemaV2.self, to: SchemaV3.self)
print(MigrationReport.render(diff))
```

```
Schema diff: SchemaV2 → SchemaV3
──────────────────────────────────────────────────
  + model Author
  + Post.content: String
  - Post.body
  + Post.author (relationship)
  - Post.authorName
```

Strata **never infers renames** — a property going from `body` to `content`
always shows as a removal plus an addition. Heuristic rename inference produces
destructive false positives; in Strata renames are always user-declared via
`Rename(\.old, to: \.new)`.

### `strata` CLI

```bash
# Report tables and columns in an on-disk store
strata inspect MyApp.store

# Schema drift between declared and on-disk
strata drift MyApp.store

# Structural diff between two store files
strata store-diff OldApp.store NewApp.store
```

## Architecture

```
StrataCore        — DSL types, operations, SafeModelContainer, backup/rollback
StrataTesting     — MigrationTestCase, fixture/migrate helpers, snapshot assertions
StrataInspect     — SchemaDiff, MigrationReport, StoreIntrospector (full SQLite backend)
StrataCLI         — strata binary; inspect / diff / drift / store-diff subcommands
```

Module boundaries are strict: `StrataCore` has no dependency on `StrataTesting`
or `StrataInspect` — they can be vended separately and you can use `StrataCore`
alone if you don't need test helpers or inspection tooling.

```
MigrationPlan
    └── Stage[]
          └── MigrationOperation[] (phase-ordered: captures → body → assertions)
                 ├── Rename     — stash in willMigrate, restore in didMigrate
                 ├── Backfill   — write in didMigrate
                 ├── Transform  — capture snapshot in willMigrate, build in didMigrate
                 ├── Delete*    — remove in didMigrate
                 ├── Custom     — user closure in willMigrate and/or didMigrate
                 └── Assert.*   — check in didMigrate after all body ops
```

The bridge to SwiftData's static `SchemaMigrationPlan` protocol lives in
`_StrataAppleBridge` — a thread-safe global slot that holds the runtime stages
for the duration of a single `ModelContainer` initialisation. Concurrent
migrations serialise through the bridge's lock.

## Known limitations

**Non-optional new columns need a default value at the property level.**
SwiftData validates the destination schema before `didMigrate` runs, so
`Backfill` has not yet had a chance to execute. Add a property-level default
(`var publishedAt: Date = .distantPast`) and let `Backfill` overwrite it with
the real per-row value. This is a SwiftData constraint — Strata cannot work
around it from outside the `@Model` declaration.

**`Transform` requires an explicit `Snapshot` type.** Source and destination
model types cannot coexist in a single `ModelContext`; a Sendable intermediate
value bridges the two phases.

**Rename inference is not provided.** Strata never guesses that `body →
content` is a rename. Write `Rename(\.body, to: \.content)` explicitly — it
is one line.

**CloudKit-synced stores** are supported with one constraint: Strata
automatically downgrades `safety: .backupAndRollback` to `safety: .backupOnly`
when `cloudKitDatabase` is non-nil. Rolling back a CloudKit store risks iCloud
sync conflicts because schema changes may already have been propagated to the
cloud before the local rollback runs. The local backup is still retained for
manual recovery if migration fails.

```swift
let container = try await SafeModelContainer.make(
    for: Schema(versionedSchema: SchemaV3.self),
    plan: MyPlan.plan,
    storeURL: storeURL,
    cloudKitDatabase: .private("iCloud.com.example.MyApp")
    // safety automatically capped at .backupOnly for CloudKit stores
)
```

**`strata drift` requires a compiled schema.** The CLI can print the raw on-disk
schema but comparing it against a declared `VersionedSchema` requires calling
`StoreIntrospector.detectDrift(declared:at:)` from Swift — the CLI has no way
to load your `@Model` types at runtime.

## Roadmap

- [x] Declarative `MigrationPlan` / `Stage` DSL with result builders
- [x] `Rename` — stash-and-restore across the migration boundary
- [x] `Backfill` — populate new properties from existing data
- [x] `Transform` — explicit snapshot-based entity rebuild
- [x] `DeleteAll` / `DeleteWhere`
- [x] `CustomOperation` — arbitrary `ModelContext` escape hatch
- [x] `Assert.{noNulls, unique, count, custom}` — post-condition checks
- [x] `SafeModelContainer.make` — automatic backup, rollback, pre/post hooks
- [x] `SafeModelContainer.dryRun` — simulate without touching the real store
- [x] `MigrationTestCase` — fixture helpers, migrate helpers, chain testing
- [x] `assertMigrationSnapshot` — auto-record + byte-stable JSON diff
- [x] Benchmark + seed helpers in `StrataTesting`
- [x] `SchemaDiff.diff(from:to:)` — declared-schema diff
- [x] `MigrationReport.render` — human-readable diff and plan rendering
- [x] `strata` CLI binary with inspect / diff / drift / store-diff subcommands
- [x] Integration tests against real SwiftData stores on disk
- [x] `StoreIntrospector` — SQLite backend for on-disk schema reading
- [x] `strata inspect` / `strata drift` / `strata store-diff` fully functional
- [x] `HookContext.sourceVersion` reads real schema version from store metadata
- [x] CloudKit-synced store support — `cloudKitDatabase:` parameter, auto-downgrade to `.backupOnly`
- [x] `CapturableObservable` protocol + `captureProperties(of:)` + `assertObservableState(of:matches:)` in `StrataTesting`

## Examples

The `Examples/PostsDemo` target exercises every primitive across a four-version
chain. Run the tests to see it migrate a real store end-to-end:

```bash
swift test --filter MigrationChainTests
```

## Contributing

Issues, PRs, and discussions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Chethan Nayak
