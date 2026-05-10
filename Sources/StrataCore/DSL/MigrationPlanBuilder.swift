import Foundation

/// Result builder for ``MigrationPlan`` bodies. Collects ``Stage`` values
/// in declaration order.
@resultBuilder
public enum MigrationPlanBuilder {
    public static func buildExpression(_ stage: Stage) -> [Stage] { [stage] }
    public static func buildExpression(_ stages: [Stage]) -> [Stage] { stages }

    public static func buildBlock(_ components: [Stage]...) -> [Stage] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [Stage]?) -> [Stage] {
        component ?? []
    }

    public static func buildEither(first: [Stage]) -> [Stage]  { first }
    public static func buildEither(second: [Stage]) -> [Stage] { second }

    public static func buildArray(_ components: [[Stage]]) -> [Stage] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(_ component: [Stage]) -> [Stage] {
        component
    }
}
