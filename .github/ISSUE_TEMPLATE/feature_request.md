---
name: Feature request
about: Suggest a new operation, primitive, or behavior
title: '[Feature] '
labels: enhancement
---

## The problem this would solve

<!-- A concrete migration you couldn't express cleanly with the current
     primitives, or a recurring boilerplate pattern you'd like to
     factor out. One short paragraph. -->

## Proposed shape

<!-- Sketch the API at the call site. Don't worry about implementation
     yet — the user-facing surface is what matters here. -->

```swift
Stage(from: ..., to: ...) {
    YourProposedOperation(...)
}
```

## Why this is hard to do today

<!-- What workaround you're using right now and why it falls short.
     "I could do it with CustomOperation but..." is a valid framing. -->

## Alternatives considered

<!-- If you can think of another shape, list it. The wrong API
     ratified into 1.0 is harder to unwind than no API. -->

## Out of scope

<!-- Things this proposal does NOT cover, to keep review focused. -->
