public import Foundation
@preconcurrency public import SwiftData

/// V3 normalises authors into their own entity and renames `body` to
/// `content`. Custom migration: ``Rename`` preserves body values,
/// ``CustomOperation`` denormalises authorName into Author rows and
/// links posts to them.
public enum PostsSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
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
        /// Renamed from `body` in V2. Defaults to an empty string so the
        /// migration validation passes before ``Rename`` runs in
        /// `didMigrate` to restore the source value.
        public var content: String = ""
        public var createdAt: Date = Date.distantPast
        public var author: Author?

        public init(
            id: String,
            title: String,
            content: String,
            createdAt: Date,
            author: Author? = nil
        ) {
            self.id = id
            self.title = title
            self.content = content
            self.createdAt = createdAt
            self.author = author
        }
    }
}
