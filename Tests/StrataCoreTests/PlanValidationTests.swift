import XCTest
import SwiftData
@testable import StrataCore
import PostsDemo

final class PlanValidationTests: XCTestCase {

    func test_empty_plan_validation_fails() {
        let plan = MigrationPlan(schemas: []) {}
        let reasons = plan.validate()
        XCTAssertFalse(reasons.isEmpty)
        XCTAssertTrue(reasons.contains { $0.contains("no stages") })
    }

    func test_real_posts_plan_validates() {
        let reasons = PostsMigrationPlan.plan.validate()
        XCTAssertEqual(reasons, [], "Posts plan should validate; got: \(reasons)")
    }

    func test_plan_detects_missing_intermediate_schema() {
        // V1 → V2 → V4 with V3 missing from schemas should report a gap.
        let plan = MigrationPlan(schemas: [
            PostsSchemaV1.self, PostsSchemaV2.self, PostsSchemaV4.self,
        ]) {
            Stage(from: PostsSchemaV1.self, to: PostsSchemaV2.self)
            Stage(from: PostsSchemaV3.self, to: PostsSchemaV4.self)
        }
        let reasons = plan.validate()
        XCTAssertTrue(
            reasons.contains { $0.contains("not in plan.schemas") || $0.contains("gap") },
            "Expected a gap or missing-schema reason; got \(reasons)"
        )
    }

    func test_plan_detects_non_adjacent_stages() {
        // V1 → V2 followed by V3 → V4 leaves V2 → V3 unspecified.
        let plan = MigrationPlan(schemas: [
            PostsSchemaV1.self, PostsSchemaV2.self,
            PostsSchemaV3.self, PostsSchemaV4.self,
        ]) {
            Stage(from: PostsSchemaV1.self, to: PostsSchemaV2.self)
            Stage(from: PostsSchemaV3.self, to: PostsSchemaV4.self)
        }
        let reasons = plan.validate()
        XCTAssertTrue(
            reasons.contains { $0.contains("gap") },
            "Expected a gap reason; got \(reasons)"
        )
    }
}
