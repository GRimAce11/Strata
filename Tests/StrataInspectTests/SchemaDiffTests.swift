import XCTest
import SwiftData
import StrataInspect
import PostsDemo

final class SchemaDiffTests: XCTestCase {

    func test_V1_to_V2_diff_reports_added_attribute() {
        let diff = SchemaDiff.diff(from: PostsSchemaV1.self, to: PostsSchemaV2.self)
        XCTAssertFalse(diff.isEmpty)
        let added = diff.changes.contains { change in
            if case .attributeAdded(_, "authorName", _) = change { return true }
            return false
        }
        XCTAssertTrue(added, "Expected V2 diff to include attributeAdded(authorName); got \(diff.changes)")
    }

    func test_V2_to_V3_diff_reports_rename_as_remove_plus_add() {
        // Strata never infers renames — body → content shows up as a
        // removal + an addition, which is the correct conservative output.
        let diff = SchemaDiff.diff(from: PostsSchemaV2.self, to: PostsSchemaV3.self)

        let removedBody = diff.changes.contains { change in
            if case .attributeRemoved(_, "body") = change { return true }
            return false
        }
        let addedContent = diff.changes.contains { change in
            if case .attributeAdded(_, "content", _) = change { return true }
            return false
        }
        let addedAuthorModel = diff.changes.contains { change in
            if case .modelAdded(let name) = change, name.contains("Author") { return true }
            return false
        }

        XCTAssertTrue(removedBody, "Expected `body` removal in V2 → V3 diff")
        XCTAssertTrue(addedContent, "Expected `content` addition in V2 → V3 diff")
        XCTAssertTrue(addedAuthorModel, "Expected new Author model in V2 → V3 diff")
    }

    func test_identical_schemas_produce_empty_diff() {
        let diff = SchemaDiff.diff(from: PostsSchemaV1.self, to: PostsSchemaV1.self)
        XCTAssertTrue(diff.isEmpty)
    }

    func test_render_is_human_readable() {
        let diff = SchemaDiff.diff(from: PostsSchemaV1.self, to: PostsSchemaV2.self)
        let rendered = MigrationReport.render(diff)
        XCTAssertTrue(rendered.contains("PostsSchemaV1"))
        XCTAssertTrue(rendered.contains("PostsSchemaV2"))
        XCTAssertTrue(rendered.contains("authorName"))
    }
}
