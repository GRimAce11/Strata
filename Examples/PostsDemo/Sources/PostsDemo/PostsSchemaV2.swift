public import Foundation
public import SwiftData

/// V2 adds an optional authorName. Lightweight migration: SwiftData
/// adds the column with a nil default, no data movement required.
public enum PostsSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static let models: [any PersistentModel.Type] = [Post.self]

    @Model public final class Post {
        @Attribute(.unique) public var id: String
        public var title: String
        public var body: String
        public var createdAt: Date
        public var authorName: String?

        public init(
            id: String,
            title: String,
            body: String,
            createdAt: Date,
            authorName: String? = nil
        ) {
            self.id = id
            self.title = title
            self.body = body
            self.createdAt = createdAt
            self.authorName = authorName
        }
    }
}
