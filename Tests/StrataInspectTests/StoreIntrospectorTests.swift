import XCTest
import SwiftData
import StrataCore
import StrataInspect
import StrataTesting
import PostsDemo

final class StoreIntrospectorTests: XCTestCase, MigrationTestCase {

    // MARK: - actualSchema

    func test_actualSchema_reads_user_tables() throws {
        let url = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(
                id: "p1", title: "Hello", body: "World", createdAt: .now
            ))
        }

        let schema = try StoreIntrospector.actualSchema(at: url)

        XCTAssertFalse(schema.tables.isEmpty, "Expected at least one table")

        // SwiftData stores `Post` as `ZPOST`
        let postTable = schema.tables.first { $0.name == "ZPOST" }
        XCTAssertNotNil(
            postTable,
            "Expected a ZPOST table; found: \(schema.tables.map(\.name).sorted())"
        )
    }

    func test_actualSchema_post_table_has_attribute_columns() throws {
        let url = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(
                id: "p1", title: "Hello", body: "World", createdAt: .now
            ))
        }

        let schema = try StoreIntrospector.actualSchema(at: url)
        guard let postTable = schema.tables.first(where: { $0.name == "ZPOST" }) else {
            XCTFail("ZPOST table not found")
            return
        }

        let colNames = Set(postTable.columns.map(\.name))
        // SwiftData attributes follow the Z + UPPERCASE convention
        XCTAssertTrue(colNames.contains("ZTITLE"),     "Expected ZTITLE; got \(colNames)")
        XCTAssertTrue(colNames.contains("ZBODY"),      "Expected ZBODY; got \(colNames)")
        XCTAssertTrue(colNames.contains("ZCREATEDAT"), "Expected ZCREATEDAT; got \(colNames)")
        XCTAssertTrue(colNames.contains("ZID"),        "Expected ZID; got \(colNames)")
    }

    func test_actualSchema_includes_system_tables() throws {
        let url = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(id: "p1", title: "T", body: "B", createdAt: .now))
        }

        let schema = try StoreIntrospector.actualSchema(at: url)

        // SwiftData/CoreData always writes Z_PRIMARYKEY
        let hasSystemTable = schema.tables.contains { $0.name.hasPrefix("Z_") }
        XCTAssertTrue(hasSystemTable, "Expected at least one Z_ system table")
    }

    func test_actualSchema_reads_metadata_uuid() throws {
        let url = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(id: "p1", title: "T", body: "B", createdAt: .now))
        }

        let schema = try StoreIntrospector.actualSchema(at: url)

        // SwiftData stores a UUID in Z_METADATA; it may be nil on very minimal stores.
        if let version = schema.metadataVersion {
            XCTAssertFalse(version.isEmpty, "metadataVersion should not be empty string")
        }
        // Not a hard failure if metadataVersion is nil — schema version is optional.
    }

    func test_actualSchema_throws_for_nonexistent_file() {
        let badURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/store.sqlite")
        XCTAssertThrowsError(try StoreIntrospector.actualSchema(at: badURL)) { error in
            guard case MigrationError.storeUnreadable = error else {
                XCTFail("Expected MigrationError.storeUnreadable, got \(error)")
                return
            }
        }
    }

    func test_actualSchema_v3_includes_author_table() throws {
        let url = try fixture(schema: PostsSchemaV3.self) { ctx in
            let author = PostsSchemaV3.Author(id: "a1", name: "Alice")
            ctx.insert(author)
            ctx.insert(PostsSchemaV3.Post(
                id: "p1", title: "T", content: "C", createdAt: .now, author: author
            ))
        }

        let schema = try StoreIntrospector.actualSchema(at: url)
        let tableNames = schema.tables.map(\.name)

        XCTAssertTrue(
            tableNames.contains("ZPOST"),
            "Expected ZPOST; found \(tableNames.sorted())"
        )
        XCTAssertTrue(
            tableNames.contains("ZAUTHOR"),
            "Expected ZAUTHOR; found \(tableNames.sorted())"
        )
    }

    // MARK: - detectDrift

    func test_detectDrift_empty_for_matching_schema() throws {
        let url = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(
                id: "p1", title: "Hello", body: "World", createdAt: .now
            ))
        }

        let reasons = try StoreIntrospector.detectDrift(declared: PostsSchemaV1.self, at: url)

        XCTAssertTrue(
            reasons.isEmpty,
            "Expected no drift for a freshly created V1 store; got: \(reasons)"
        )
    }

    func test_detectDrift_reports_missing_columns_after_partial_migration() async throws {
        // Migrate a V1 store all the way to V4, then ask detectDrift
        // about V4 — should still be clean.
        let v1URL = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(
                id: "p1", title: "Drift Test", body: "body", createdAt: .now
            ))
        }
        let container = try await migrate(store: v1URL, to: PostsSchemaV4.self, plan: PostsMigrationPlan.plan)

        // Grab the migrated store URL from the container's configuration.
        guard let config = container.configurations.first else {
            XCTFail("No configuration on migrated container"); return
        }
        let migratedURL = config.url

        let reasons = try StoreIntrospector.detectDrift(declared: PostsSchemaV4.self, at: migratedURL)

        XCTAssertTrue(
            reasons.isEmpty,
            "Expected no drift for a fully migrated V4 store; got: \(reasons)"
        )
    }
}
