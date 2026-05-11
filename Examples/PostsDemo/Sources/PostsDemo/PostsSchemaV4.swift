public import Foundation
public import SwiftData

/// V4 adds non-optional `publishedAt: Date` and a `slug: String`.
///
/// **SwiftData migration constraint:** lightweight migration validates
/// the destination schema *before* a custom stage's `didMigrate`
/// closure runs. New non-optional columns therefore need a default
/// value at the property level — ``Backfill`` will then overwrite it
/// with the real per-row value. Strata cannot work around this from
/// outside the schema declaration.
///
/// We also keep `slug` non-unique here and assert uniqueness via
/// ``Assert/unique(_:)`` in the migration plan — adding `@Attribute(.unique)`
/// to a defaulted column would fail validation when multiple rows
/// briefly share the empty-string default.
public enum PostsSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    public static let models: [any PersistentModel.Type] = [Post.self, Author.self]

    @Model public final class Author {
        @Attribute(.unique) public var id: String
        public var name: String
        @Relationship(deleteRule: .nullify, inverse: \Post.author)
        public var posts: [Post] = []

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    @Model public final class Post {
        @Attribute(.unique) public var id: String
        public var title: String
        public var content: String = ""
        public var createdAt: Date = Date.distantPast
        public var publishedAt: Date = Date.distantPast
        public var slug: String = ""
        public var author: Author?

        public init(
            id: String,
            title: String,
            content: String,
            createdAt: Date,
            publishedAt: Date,
            slug: String,
            author: Author? = nil
        ) {
            self.id = id
            self.title = title
            self.content = content
            self.createdAt = createdAt
            self.publishedAt = publishedAt
            self.slug = slug
            self.author = author
        }
    }
}
