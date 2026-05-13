---
name: Bug report
about: A migration produced an unexpected result, or Strata crashed
title: '[Bug] '
labels: bug
---

## What happened

<!-- One sentence -->

## Reproducer

<!--
The most useful bug report is a minimal MigrationPlan plus the
smallest fixture that triggers the issue. If you can express it as a
failing test against PostsDemo, even better.
-->

```swift
let plan = MigrationPlan(schemas: [...]) {
    ...
}
```

Fixture:

```swift
try fixture(schema: ...) { ctx in
    ctx.insert(...)
}
```

## Expected

<!-- What you thought would happen -->

## Actual

<!-- What did happen — paste the assertion failure, error message, or
     console output. Include the rendered MigrationError if applicable. -->

## Environment

- Strata version (tag or commit):
- Xcode version:
- `swift --version` output:
- Deployment target (iOS / macOS / both):
- SwiftData feature flags (CloudKit sync, history tracking, etc.):
