public import StrataCore
import Foundation

/// Renders human-readable text reports for diffs and migration plans.
///
/// `MigrationReport.render(_:)` is the canonical way to produce the
/// output you'd want to paste into a PR description, code-review
/// thread, or CI log — it tries to be skim-readable rather than
/// exhaustive.
public enum MigrationReport {

    /// Render a ``SchemaDiff`` as plain text.
    public static func render(_ diff: SchemaDiff) -> String {
        var out: [String] = []
        out.append("Schema diff: \(diff.from) → \(diff.to)")
        out.append(String(repeating: "─", count: 50))

        if diff.changes.isEmpty {
            out.append("(no changes)")
            return out.joined(separator: "\n")
        }

        for change in diff.changes {
            out.append("  \(symbol(for: change)) \(line(for: change))")
        }
        return out.joined(separator: "\n")
    }

    /// Render a ``MigrationPlan`` as plain text.
    public static func render(_ plan: MigrationPlan) -> String {
        var out: [String] = []
        out.append("Migration plan: \(plan.stages.count) stage(s), \(plan.schemas.count) schema(s)")
        out.append(String(repeating: "─", count: 50))
        for (i, stage) in plan.stages.enumerated() {
            switch stage.kind {
            case .lightweight:
                out.append("[\(i)] \(stage.label) — lightweight")
            case .custom:
                out.append("[\(i)] \(stage.label) — custom (\(stage.operations.count) op\(stage.operations.count == 1 ? "" : "s"))")
                for op in stage.operations {
                    out.append("       · \(op.description)")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private static func symbol(for change: SchemaDiff.Change) -> String {
        switch change {
        case .modelAdded, .attributeAdded, .relationshipAdded:                              return "+"
        case .modelRemoved, .attributeRemoved, .relationshipRemoved:                        return "-"
        case .attributeTypeChanged, .attributeNullabilityChanged, .attributeUniquenessChanged: return "~"
        }
    }

    private static func line(for change: SchemaDiff.Change) -> String {
        switch change {
        case .modelAdded(let name):
            return "model \(name)"
        case .modelRemoved(let name):
            return "model \(name)"
        case .attributeAdded(let model, let name, let type):
            return "\(model).\(name): \(type)"
        case .attributeRemoved(let model, let name):
            return "\(model).\(name)"
        case .attributeTypeChanged(let model, let name, let from, let to):
            return "\(model).\(name): \(from) → \(to)"
        case .attributeNullabilityChanged(let model, let name, let fromOpt, let toOpt):
            return "\(model).\(name): \(fromOpt ? "?" : "!") → \(toOpt ? "?" : "!")"
        case .attributeUniquenessChanged(let model, let name, let fromUnique, let toUnique):
            return "\(model).\(name): unique=\(fromUnique) → unique=\(toUnique)"
        case .relationshipAdded(let model, let name):
            return "\(model).\(name) (relationship)"
        case .relationshipRemoved(let model, let name):
            return "\(model).\(name) (relationship)"
        }
    }
}
