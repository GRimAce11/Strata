import Foundation

/// Result builder for the body of a ``Stage``. Collects ``MigrationOperation``
/// values declared in a stage's closure into an ordered array.
///
/// Conditionals, `for`-loops, and `if let` all work as expected — every
/// branch's expressions contribute operations to the final array in source
/// order.
@resultBuilder
public enum StageBuilder {
    public static func buildExpression(_ op: any MigrationOperation) -> [any MigrationOperation] {
        [op]
    }

    public static func buildExpression(_ ops: [any MigrationOperation]) -> [any MigrationOperation] {
        ops
    }

    public static func buildBlock(_ components: [any MigrationOperation]...) -> [any MigrationOperation] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [any MigrationOperation]?) -> [any MigrationOperation] {
        component ?? []
    }

    public static func buildEither(first: [any MigrationOperation]) -> [any MigrationOperation] {
        first
    }

    public static func buildEither(second: [any MigrationOperation]) -> [any MigrationOperation] {
        second
    }

    public static func buildArray(_ components: [[any MigrationOperation]]) -> [any MigrationOperation] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(_ component: [any MigrationOperation]) -> [any MigrationOperation] {
        component
    }
}
