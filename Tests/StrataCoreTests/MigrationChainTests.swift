import XCTest
import SwiftData
import StrataCore
import StrataTesting
import PostsDemo

/// End-to-end migration tests against the Posts demo plan.
///
/// These exercise the actual SwiftData migration machinery — they
/// build a real SQLite store at V1, run the plan, and inspect the V4
/// store. If these fail, something fundamental in StrataCore is broken.
final class MigrationChainTests: XCTestCase, MigrationTestCase {

    func test_V1_to_V2_is_lightweight_and_preserves_posts() async throws {
        let v1Store = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(
                id: "p1", title: "Hello", body: "World", createdAt: .now
            ))
        }

        let plan = MigrationPlan(schemas: [
            PostsSchemaV1.self, PostsSchemaV2.self,
        ]) {
            Stage(from: PostsSchemaV1.self, to: PostsSchemaV2.self)
        }

        let container = try await migrate(store: v1Store, to: PostsSchemaV2.self, plan: plan)
        let context = ModelContext(container)
        let posts = try context.fetch(FetchDescriptor<PostsSchemaV2.Post>())

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.title, "Hello")
        XCTAssertEqual(posts.first?.body, "World")
        XCTAssertNil(posts.first?.authorName)
    }

    func test_V2_to_V3_rename_preserves_body_as_content() async throws {
        let v2Store = try fixture(schema: PostsSchemaV2.self) { ctx in
            ctx.insert(PostsSchemaV2.Post(
                id: "p1", title: "Hello", body: "Renamed payload",
                createdAt: .now, authorName: "Alice"
            ))
        }

        let plan = MigrationPlan(schemas: [
            PostsSchemaV2.self, PostsSchemaV3.self,
        ]) {
            Stage(from: PostsSchemaV2.self, to: PostsSchemaV3.self) {
                Rename(
                    \PostsSchemaV2.Post.body,
                    to: \PostsSchemaV3.Post.content
                )
            }
        }

        let container = try await migrate(store: v2Store, to: PostsSchemaV3.self, plan: plan)
        let posts = try ModelContext(container).fetch(FetchDescriptor<PostsSchemaV3.Post>())

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(
            posts.first?.content, "Renamed payload",
            "Rename should preserve `body` value into `content`"
        )
    }

    func test_full_V1_to_V4_chain_backfills_publishedAt() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let v1Store = try fixture(schema: PostsSchemaV1.self) { ctx in
            ctx.insert(PostsSchemaV1.Post(
                id: "p1", title: "Sample", body: "Body", createdAt: createdAt
            ))
        }

        let container = try await migrate(
            store: v1Store,
            to: PostsSchemaV4.self,
            plan: PostsMigrationPlan.plan
        )
        let posts = try ModelContext(container).fetch(FetchDescriptor<PostsSchemaV4.Post>())

        XCTAssertEqual(posts.count, 1)
        guard let post = posts.first else { return }
        XCTAssertEqual(post.content, "Body")
        XCTAssertEqual(post.publishedAt, createdAt, "Backfill should set publishedAt from createdAt")
        XCTAssertFalse(post.slug.isEmpty, "Slug should have been backfilled")
        XCTAssertTrue(post.slug.contains("sample"), "Slug should derive from title; got \(post.slug)")
    }

    func test_unique_assertion_catches_duplicate_slugs() async throws {
        // Build a fixture where two posts have identical titles and IDs that
        // collide once truncated — exposing a slug duplicate.
        let v3Store = try fixture(schema: PostsSchemaV3.self) { ctx in
            let author = PostsSchemaV3.Author(id: "a1", name: "Alice")
            ctx.insert(author)
            ctx.insert(PostsSchemaV3.Post(
                id: "abc12345", title: "Same Title", content: "x", createdAt: .now, author: author
            ))
            ctx.insert(PostsSchemaV3.Post(
                id: "abc12399", title: "Same Title", content: "y", createdAt: .now, author: author
            ))
        }

        let plan = MigrationPlan(schemas: [
            PostsSchemaV3.self, PostsSchemaV4.self,
        ]) {
            Stage(from: PostsSchemaV3.self, to: PostsSchemaV4.self) {
                Backfill(\PostsSchemaV4.Post.publishedAt) { $0.createdAt }
                // Intentionally produce a colliding slug by using only the
                // title and the first three id chars.
                Backfill(\PostsSchemaV4.Post.slug) { post in
                    PostsSlug.slugify(post.title) + "-" + post.id.prefix(3)
                }
                Assert.unique(\PostsSchemaV4.Post.slug)
            }
        }

        do {
            _ = try await migrate(store: v3Store, to: PostsSchemaV4.self, plan: plan)
            XCTFail("Expected Assert.unique to throw on duplicate slugs")
        } catch {
            // SwiftData wraps custom-stage throws in `loadIssueModelContainer`,
            // which Strata then wraps in `migrationFailed`. We assert the
            // outer shape and look for our message in the rendered string.
            let rendered = String(describing: error)
            XCTAssertTrue(
                rendered.contains("Migration failed") || rendered.contains("duplicate"),
                "Expected migration failure or duplicate-mention; got \(rendered)"
            )
        }
    }
}
