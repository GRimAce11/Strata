# Contributing to Strata

Thanks for the interest. Strata is in early v0.x — the public surface is
still settling, so I am being deliberate about what gets merged.

## Before you open a PR

1. **File an issue first** for anything larger than a typo or small bug
   fix. A short discussion saves rework when the design choice would
   conflict with where I'm taking the library next.
2. **Read the README's "Known limitations" section.** Several rough
   edges (non-optional column defaults, `Transform` requiring an
   explicit `Snapshot`, no rename inference) are intentional design
   choices, not gaps to fill.

## Development setup

```bash
git clone git@github.com:GRimAce11/Strata.git
cd Strata
swift build
swift test --parallel
.build/debug/strata --help
```

The package targets iOS 17 / macOS 14 / Swift 6. CI runs against
`macos-15` with the bundled Xcode 16.

## What changes are easy to merge

- Bug fixes with a regression test.
- Documentation improvements (README, inline doc comments, CHANGELOG
  for `[Unreleased]`).
- New `Assert` variants that don't change the public protocols.
- Additional operations that follow the same `MigrationOperation`
  conformance pattern.

## What needs more discussion first

- Changes to `MigrationOperation`, `MigrationPlan`, or `Stage` shapes.
- Anything that touches `SafeModelContainer.make`'s lifecycle or the
  `_StrataAppleBridge` bridge.
- New module-level dependencies (Strata is deliberately
  Apple-platform-and-SwiftData-only — keep it that way).
- Rename inference (we don't, for a reason — see the README).

## Style

- Match the existing tone of doc comments: short prose, then a short
  example, then an explanation if non-obvious. Don't paraphrase the
  function signature.
- Operations should run in their declared phase (captures / body /
  assertions). Don't add phase-mixing operations.
- Strict concurrency is on. Mark types `Sendable` (or
  `@unchecked Sendable` with a one-line "why this is sound" comment).

## Tests

Every new operation needs at least one integration test that:

1. Fixtures a source schema with realistic data.
2. Migrates through a plan exercising the operation.
3. Asserts on the resulting store.

Use `PostsSchemaV1`…`V4` from `PostsDemo` rather than inventing new
test-only schemas unless the new behavior genuinely doesn't fit.

## Releasing

1. Update `CHANGELOG.md` — move items from `[Unreleased]` into a new version section with today's date.
2. Bump the version reference in `README.md` installation snippet if needed.
3. Commit: `git commit -m "chore: release x.y.z"`.
4. Tag: `git tag -a x.y.z -m "x.y.z"` and `git push origin x.y.z`.
5. Draft a GitHub release pointing at the tag and copy the CHANGELOG section as the body.

## Reporting bugs

File on the issue tracker with:

- Strata version (tag or commit SHA).
- Xcode / Swift version.
- A reduced reproducer — a minimal `MigrationPlan` and the smallest
  fixture that demonstrates the bug.
- Expected vs actual behavior.

Bugs that include a failing test against `PostsDemo` get fixed faster.
