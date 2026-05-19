public import Foundation
public import SwiftData
public import StrataCore

/// The Posts demo's full migration plan, V1 → V4.
///
/// Demonstrates every primitive Strata ships:
///
/// - `Stage(from:to:)` without a body — a lightweight migration.
/// - ``Rename`` — preserves `body` across the rename to `content`.
/// - ``CustomOperation`` — fabricates `Author` rows linked to posts.
/// - ``Backfill`` — fills the new non-optional `publishedAt` and `slug`.
/// - ``Assert/unique(_:)`` — post-condition on the slug.
public enum PostsMigrationPlan {

    public static let plan: MigrationPlan = MigrationPlan(
        schemas: [
            PostsSchemaV1.self,
            PostsSchemaV2.self,
            PostsSchemaV3.self,
            PostsSchemaV4.self,
        ]
    ) {
        // V1 → V2: SwiftData adds an optional column. No data work.
        Stage(from: PostsSchemaV1.self, to: PostsSchemaV2.self)

        // V2 → V3: rename `body` → `content`, then attach an Author.
        // sourceKey:/destinationKey: uses the stable user-defined `id` field
        // for row identity — safe even when the @Model class name changes.
        Stage(from: PostsSchemaV2.self, to: PostsSchemaV3.self) {
            Rename(
                \PostsSchemaV2.Post.body,
                to: \PostsSchemaV3.Post.content,
                sourceKey: \PostsSchemaV2.Post.id,
                destinationKey: \PostsSchemaV3.Post.id
            )

            CustomOperation(
                "Attach a default Author to every post lacking one",
                didMigrate: { context in
                    let posts = try context.fetch(FetchDescriptor<PostsSchemaV3.Post>())
                    var authorsByName: [String: PostsSchemaV3.Author] = [:]
                    for post in posts where post.author == nil {
                        let name = "Unknown"
                        let author = authorsByName[name] ?? {
                            let new = PostsSchemaV3.Author(id: UUID().uuidString, name: name)
                            context.insert(new)
                            authorsByName[name] = new
                            return new
                        }()
                        post.author = author
                    }
                }
            )
        }

        // V3 → V4: add non-optional publishedAt and unique slug.
        Stage(from: PostsSchemaV3.self, to: PostsSchemaV4.self) {
            Backfill(\PostsSchemaV4.Post.publishedAt) { post in
                post.createdAt
            }

            Backfill(\PostsSchemaV4.Post.slug) { post in
                PostsSlug.slugify(post.title) + "-" + post.id.prefix(6)
            }

            Assert.unique(\PostsSchemaV4.Post.slug)
        }
    }
}

/// Minimal Unicode-friendly slugger used by the V4 backfill.
public enum PostsSlug {
    public static func slugify(_ input: String) -> String {
        let mapped = input.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        var out = ""
        var lastWasDash = false
        for ch in mapped {
            if ch == "-" {
                if !lastWasDash, !out.isEmpty { out.append(ch) }
                lastWasDash = true
            } else {
                out.append(ch)
                lastWasDash = false
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
