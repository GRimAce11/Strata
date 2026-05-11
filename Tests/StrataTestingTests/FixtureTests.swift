import XCTest
import SwiftData
import StrataCore
import StrataTesting
import PostsDemo

final class FixtureTests: XCTestCase, MigrationTestCase {

    func test_fixture_creates_a_populated_store() throws {
        let url = try fixture(schema: PostsSchemaV1.self) { ctx in
            for i in 0..<3 {
                ctx.insert(PostsSchemaV1.Post(
                    id: "p\(i)", title: "T\(i)", body: "B\(i)", createdAt: .now
                ))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Fixture URL should exist on disk: \(url.path)")

        let container = try ModelContainer(
            for: Schema(versionedSchema: PostsSchemaV1.self),
            configurations: ModelConfiguration(
                schema: Schema(versionedSchema: PostsSchemaV1.self), url: url
            )
        )
        let count = try ModelContext(container).fetchCount(FetchDescriptor<PostsSchemaV1.Post>())
        XCTAssertEqual(count, 3)
    }
}
